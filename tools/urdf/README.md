# URDF / xacro (sw2robot + GitHub Actions)

The URDF of the MIRTE Master is generated with [sw2robot](https://github.com/jsk-ros-pkg/solidworks_urdf_exporter2)
in two halves, because GitHub's runners cannot run SolidWorks:

```
 Windows PC with SolidWorks                              GitHub Action (.github/workflows/urdf.yml)
 ──────────────────────────                              ──────────────────────────────────────────
 sw2robot editor: extract + fix joints                   1. stale check: CAD hashes == recorded hashes?
        │                                                2. sw2robot build (no SolidWorks)
 tools/urdf/Sync-Sw2Robot.ps1                            3. joint check: joint config == built model?
        │  commits                                       4. URDF + xacro, validated
        ▼                                                5. artifact "urdf" (every push), release (tag v*)
 sw2robot/MM_Minimal/              extract: graph.json + meshes
 sw2robot/MM_Minimal.joints.yaml   joint config: the kinematic tree (fixed / revolute, limits, root, ...)
 sw2robot/MM_Minimal.sources.json  SHA-256 of the SolidWorks files the extract was made from
```

The joint config is the source of truth for the kinematics. Never hand-edit a generated URDF.

## When do I need to do something?

| You changed | What to do |
|---|---|
| Nothing in `solidworks/` | Nothing. The Action builds the URDF. |
| Anything in `solidworks/` (any `.SLDPRT` / `.SLDASM`) | Re-extract: run `Sync-Sw2Robot.ps1`, extract in the editor, commit `sw2robot/`. Otherwise the Action fails with *"sw2robot extract is out of date"*. |
| Only joints (fixed / revolute, limits, ...) | `Sync-Sw2Robot.ps1 -FromRepo` (no SolidWorks needed), or edit the YAML directly. Commit `sw2robot/`. |

Check before pushing: `.\tools\urdf\Sync-Sw2Robot.ps1 -Check` (does the same stale check as the Action).

## Re-extracting (Windows + SolidWorks)

Requirements: SolidWorks, and the sw2robot editor (`sw2robot-web.exe`), installed with

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://jsk-ros-pkg.github.io/solidworks_urdf_exporter2/install.ps1 | iex"
```

Then, from the repository root, with your SolidWorks changes **saved**:

```powershell
.\tools\urdf\Sync-Sw2Robot.ps1
```

1. The script puts the committed joint config into the editor's folder (`%TEMP%\sw2robot\output\MM_Minimal`), so
   you start from the committed joint settings, and starts the editor.
2. In the browser: open `solidworks\MM-Minimal.SLDASM` (🗄 file browser or 📋 path bar) to extract it again.
3. Check the joints. A new or re-inserted part gets a **guessed** joint type, so check it. Keys: `t` fixed ↔ movable,
   `f` flip axis, `r` make root.
4. **Close the editor's console window.** The script then imports the result into `sw2robot/`:
   - absolute paths become repository-relative and the Windows user name is removed from the meshes (public repo);
   - the CAD hashes are recorded in `MM_Minimal.sources.json`.
5. Review and commit: `git diff -- sw2robot/MM_Minimal.joints.yaml`, then `git add sw2robot` and commit.

The import refuses when the extract is incomplete, is of another assembly, or is older than a SolidWorks file
(saved after extracting). Use `-Force` only when just the timestamps changed (e.g. after a `git checkout`).

| Option | Meaning |
|---|---|
| `-FromRepo` | Open the editor on the committed extract (change only joints; no SolidWorks needed). |
| `-ImportOnly` | Do not start the editor; import what is in the editor's folder (if you used the editor yourself). |
| `-Check` | Only check whether the committed extract matches the SolidWorks files. |
| `-PackageDir <dir>` | Another editor package folder. |
| `-Force` | Import even when SolidWorks files are newer than the extract. |

## What the Action checks (and how it fails)

| Failure | Cause | Fix |
|---|---|---|
| *sw2robot extract is out of date with the SolidWorks model* | A SolidWorks file was changed / added / removed after the last extract. The message lists them. | Re-extract (above). |
| *Joint config does not match the model* | A joint config entry matches no joint (part renamed, removed or re-inserted), a joint in the model is not in the config (sw2robot guessed its type), or a type differs. sw2robot itself only warns, so the Action checks this. | `Sync-Sw2Robot.ps1` (or `-FromRepo`), fix the joints, commit. |
| *sw2robot build failed* | Usually an incomplete extract (missing meshes). | Re-extract. |
| *Generated URDF / xacro is invalid* | Broken tree or a bug in `build_urdf.py`. | Look at the log. |

sw2robot warnings (e.g. geometry missing from the URDF) appear as warnings on the run and in `build_info.json`;
they do not fail the build.

## Output

Every push: the Actions run has an artifact **`urdf`**. Pushing a tag `v*` (e.g. `git tag v1.0 && git push origin v1.0`)
also creates a GitHub release with `mirte-master-frame-urdf-<tag>.zip`. Contents:

| Path | Contents |
|---|---|
| `MM_Minimal/urdf/MM_Minimal.urdf` | URDF with mesh paths relative to the file (`../meshes/...`) |
| `MM_Minimal/urdf/MM_Minimal.macro.xacro` | xacro macro `mm_minimal` (params: `prefix`, `mesh_path`, `parent`, `xyz`, `rpy`) |
| `MM_Minimal/urdf/MM_Minimal.urdf.xacro` | Uses the macro; args `prefix`, `mesh_path` (default `../meshes`) |
| `MM_Minimal/meshes/` | `.dae` visuals (with colours), `.stl` collisions |
| `MM_Minimal/build_info.json` | Commit, sw2robot version, joint config hash, link / joint counts, sw2robot warnings |

### Simplification (`merge_fixed`, `combine_meshes`, `dedupe_meshes`)

The joint config describes every part (58 joints, mostly fixed). For the output, with these options on (default):

- **`merge_fixed`**: every fixed-joint child is folded into its parent, so only the movable joints remain
  (9: four wheels and five arm joints). Mass and inertia are lumped; the movable joint frames are unchanged.
  Links **without geometry** are kept, so a sensor frame you want in the URDF (e.g. `lidar_link`, `camera_link`) can
  be added as a **⊕ Port** in the sw2robot editor. It then survives the merge.
- **`combine_meshes`**: each link gets one `.dae` (every part keeps its own colour) and one `.stl`.
- **`dedupe_meshes`**: links with the same geometry (the same part used several times, e.g. the four wheels) share
  one mesh file, placed with the `<origin>` of the visual / collision. Only an exact rigid copy (rotation +
  translation, same colours) is shared, so mirrored parts (left vs. right Mecanum wheel) keep their own file.
  The shared file is named after the links without their instance number (`Mecanum_Wheel_dia_100_left.dae`), and
  `build_info.json` lists which links use it.

The joint check always runs on the full, unmerged model, so it still catches renamed / new parts.

In a ROS package, include the macro and pass `mesh_path:=package://<your_pkg>/meshes`. With `parent` set it adds a
fixed joint from `parent` to `${prefix}base_link` at `xyz` / `rpy`.

## Running the build locally

Optional (Python 3.12+):

```powershell
python -m venv .venv-urdf; .\.venv-urdf\Scripts\pip install sw2robot==<version in sw2robot/MM_Minimal.sources.json> xacro==2.1.1
.\.venv-urdf\Scripts\python tools\urdf\build_urdf.py          # output in build/urdf-dist
```

## Config (`urdf.config.json`)

| Key | Meaning |
|---|---|
| `assembly` | Assembly, relative to the repository root. |
| `robot_name` | Robot name; also the names of the extract folder and the joint config (`<robot_name>.joints.yaml`). |
| `sw2robot_dir` | Folder with the extract, joint config and hashes (default `sw2robot`). |
| `cad_dir` | Folder whose `.SLDPRT` / `.SLDASM` files are hashed (default `solidworks`). Any change there needs a new extract. |
| `editor_exe` | Path to `sw2robot-web.exe`. |
| `merge_fixed` | Merge fixed links into their parents; only movable joints (and geometry-less frames) remain. |
| `combine_meshes` | One visual `.dae` and one collision `.stl` per link. |
| `dedupe_meshes` | With `combine_meshes`: links with identical geometry share one mesh file (default `true`). |
| `build_args` | Extra arguments for `python -m sw2robot.exporter.build` (see its `--help`). Default `["--collision", "hull"]`: a convex hull per part as collision geometry instead of the full mesh. Other examples: `["--ros2"]`, `["--collision", "coacd"]`. |

The Action installs the sw2robot version recorded in `graph.json` (the one that made the extract), so the local
editor and CI always match.
