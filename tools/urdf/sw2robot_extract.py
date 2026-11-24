#!/usr/bin/env python3
"""Full sw2robot extract without the editor GUI, the same steps as the editor's "Import from SolidWorks".

Used by Sync-Sw2Robot.ps1 -Extract. In the user's running SolidWorks (attach), with the assembly open and saved:
  1. sw2robot.editor.core.extract_and_import   what the editor runs: the extract (graph.json + .3dxml meshes) and
                                               the build into the package (urdf/), reusing the package's
                                               <robot>.joints.yaml
  2. the .3dxml.glb mesh previews              the editor makes these after an extract (webserver._preconvert_meshes,
                                               there in a background thread; here one by one)
  3. sw2robot.exporter.export.refresh_frames   the coordinate systems inside parts, which the extract skips

Usage: python -E tools/urdf/sw2robot_extract.py <assembly.SLDASM> <out_dir> <robot_name>
       (the package is <out_dir>/<robot_name>)
Exit code 0 = OK, 1 = failed.
"""
import os
import sys


def main():
    assembly, out_dir, robot_name = sys.argv[1:4]
    from sw2robot.editor import core
    from sw2robot.editor.webserver import _convert_3dxml_to_glb
    from sw2robot.exporter.export import refresh_frames
    from sw2robot.exporter.swcom import SolidWorks

    sw = SolidWorks(attach=True)   # the user's SolidWorks; its documents are left alone (a copy is opened)
    try:
        state = core.extract_and_import(assembly, out_dir=out_dir, robot_name=robot_name, sw=sw,
                                        progress=lambda m: print(f"[extract] {m}", flush=True))
        pkg_dir = str(state.package_dir)

        n = 0
        for dirpath, _dirs, files in os.walk(pkg_dir):
            for f in sorted(files):
                if f.lower().endswith(".3dxml"):
                    _convert_3dxml_to_glb(os.path.join(dirpath, f))
                    n += 1
        print(f"[extract] {n} mesh previews (.glb)", flush=True)

        refresh_frames(pkg_dir, sw=sw)
    finally:
        sw.shutdown()                # attach mode: leaves the user's SolidWorks running
    print(f"[extract] done: {pkg_dir}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 -- report and fail, the PowerShell script stops
        import traceback
        traceback.print_exc()
        print(f"[extract] FAILED: {e!r}", flush=True)
        sys.exit(1)
