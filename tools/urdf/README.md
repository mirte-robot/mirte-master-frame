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
| Anything in `solidworks/` (any `.SLDPRT` / `.SLDASM`) | Re-extract: run `Sync-Sw2Robot.ps1` and extract in the editor (or `-Extract`, without the editor GUI), commit `sw2robot/`. Otherwise the Action fails with *"sw2robot extract is out of date"*. |
| Only coordinate systems (sensor frames) in `solidworks/` | `Sync-Sw2Robot.ps1 -FramesOnly` (seconds), commit `sw2robot/`. |
| Only joints (fixed / revolute, limits, ...) | `Sync-Sw2Robot.ps1 -FromRepo` (no SolidWorks needed), or edit the YAML directly. Commit `sw2robot/`. |

Check before pushing: `.\tools\urdf\Sync-Sw2Robot.ps1 -Check` (does the same stale check as the Action).

## Re-extracting (Windows + SolidWorks)

Requirements: SolidWorks, and the sw2robot editor (`sw2robot-web.exe`), installed with

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://jsk-ros-pkg.github.io/solidworks_urdf_exporter2/install.ps1 | iex"
```

The script also needs the Python environment with sw2robot (`.venv-urdf`, see
[Running the build locally](#running-the-build-locally)) for the frames refresh and `-Extract`.

Then, from the repository root, with your SolidWorks changes **saved** and the assembly **open** in SolidWorks:

```powershell
.\tools\urdf\Sync-Sw2Robot.ps1
```

1. The script puts the committed joint config into the editor's folder (`%TEMP%\sw2robot\output\MM_Minimal`), so
   you start from the committed joint settings, and starts the editor.
2. In the browser: open `solidworks\MM-Minimal.SLDASM` (🗄 file browser or 📋 path bar) to extract it again.
3. Check the joints. A new or re-inserted part gets a **guessed** joint type, so check it. Keys: `t` fixed ↔ movable,
   `f` flip axis, `r` make root.
4. **Close the editor's console window.** If the editor made a new extract, the script re-reads the sensor frames in
   the running SolidWorks (see [Sensor frames](#sensor-frames)), then imports the result into `sw2robot/`:
   - absolute paths become repository-relative and the Windows user name is removed from the meshes (public repo);
   - the CAD hashes are recorded in `MM_Minimal.sources.json`.
5. **Close the assembly in SolidWorks without saving.** The extract resolves lightweight components and switches
   configurations, which marks documents as modified, but it changes nothing in them. Saving them would make the
   SolidWorks files newer than the extract (the import refuses, and the Action's stale check fails).
6. Review and commit: `git diff -- sw2robot/MM_Minimal.joints.yaml`, then `git add sw2robot` and commit.

The import refuses when the extract is incomplete, is of another assembly, misses a sensor frame, or is older than a
SolidWorks file (saved after extracting). Use `-Force` only when just the timestamps changed (e.g. after a `git checkout`).

| Option | Meaning |
|---|---|
| (none) | Editor (GUI): extract and/or fix the joints, then frames refresh (after a new extract) and import. |
| `-Extract` | Full extract **without the editor GUI**: the editor's own steps (`tools/urdf/sw2robot_extract.py`: extract + build, mesh previews) in the running SolidWorks, then the frames refresh and the import. Needs the assembly open in SolidWorks. The joints are not shown; a new or renamed part then fails the joint check of the build (fix it with `-FromRepo`). |
| `-FramesOnly` | Only re-read the coordinate systems (seconds), then import. Needs the assembly open in SolidWorks and the latest full extract in the editor's folder. **Only when nothing but coordinate systems changed:** other CAD changes are not read, but the import records the new CAD hashes, so the stale check would not notice them. |
| `-FromRepo` | Open the editor on the committed extract (change only joints; no SolidWorks needed). |
| `-ImportOnly` | Do not start the editor; import what is in the editor's folder (if you used sw2robot yourself). |
| `-Check` | Only check whether the committed extract matches the SolidWorks files. |
| `-PackageDir <dir>` | Another editor package folder. |
| `-Force` | Import even when SolidWorks files are newer than the extract. |

## What the Action checks (and how it fails)

| Failure | Cause | Fix |
|---|---|---|
| *sw2robot extract is out of date with the SolidWorks model* | A SolidWorks file was changed / added / removed after the last extract. The message lists them. | Re-extract (above). |
| *Sensor frames missing or duplicated in the sw2robot extract* | A frame in `required_frames` is not in `graph.json` (re-extracted without the frames refresh, or the coordinate system was renamed / deleted), or it appears more than once (it is in a part used several times). Also checked by `check_before_push.py`. | `Sync-Sw2Robot.ps1 -FramesOnly`, or fix the coordinate system in SolidWorks. |
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
  Links **without geometry** are kept, so the sensor frames (see below) survive the merge.
- **`combine_meshes`**: each link gets one `.dae` (every part keeps its own colour) and one `.stl`.
- **`dedupe_meshes`**: links with the same geometry (the same part used several times, e.g. the four wheels) share
  one mesh file, placed with the `<origin>` of the visual / collision. Only an exact rigid copy (rotation +
  translation, same colours) is shared, so mirrored parts (left vs. right Mecanum wheel) keep their own file.
  The shared file is named after the links without their instance number (`Mecanum_Wheel_dia_100_left.dae`), and
  `build_info.json` lists which links use it.

The joint check always runs on the full, unmerged model, so it still catches renamed / new parts.

### Wheel collisions (`collision_cylinders`)

The collision geometry is a convex hull per part (`build_args`), but the four mecanum wheels get a **cylinder**
instead: the hull of a mecanum wheel follows the rollers, so in simulation the robot rests on tilted faces at slightly
different heights, and on the frictionless simulated wheels it slowly slides. The cylinder is on the axis of the wheel
joint (so it does not wobble when the wheel turns), as long as the wheel mesh along the axis, with the nominal radius
from the config (0.050 for the 100 mm wheels; the hull is 0.052 because of the rollers). The visuals stay the CAD
meshes. If a wheel link is renamed (re-inserted in SolidWorks), the build fails until `collision_cylinders` is updated.

In a ROS package, include the macro and pass `mesh_path:=package://<your_pkg>/meshes`. With `parent` set it adds a
fixed joint from `parent` to `${prefix}base_link` at `xyz` / `rpy`.

## Sensor frames

The sensor frames (`lidar_link`, `rgbd_camera_link`, `wrist_camera_link`, `left_sonar_link`, `right_sonar_link`,
`imu_link`) and the gripper's tool frame (`gripper_tcp`, between the fingertips, in the gripper sub-assembly) are
**coordinate systems in SolidWorks**, named like the frame. Each becomes a geometry-less link in the URDF, fixed to
the link of the part (or assembly) it is in. Conventions (REP-103): x forward, y left, z up; for a camera and the
gripper x along the view / approach direction (the camera `_optical_frame`s are added in the ROS description
package). In SolidWorks red = x, green = y, blue = z.

- A frame inside a **part** goes with every instance of that part: put it in a part that is used once, or in the
  assembly. A duplicate is renamed `<link>_<name>` in the URDF.
- The coordinate systems inside parts are a slow scan, which the editor's extract skips. `Sync-Sw2Robot.ps1`
  therefore re-reads all coordinate systems after a new extract (in the editor, or with `-Extract`); `-FramesOnly`
  only re-reads them.
- `required_frames` in `urdf.config.json` lists the frames the model must have. The import, `build_urdf.py
  --check-only` (pre-push hook, first step of the Action) and the URDF validation fail when one is missing or
  appears more than once. Add a new sensor frame to this list.

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
| `required_frames` | Frames (CAD coordinate systems) that must be in the extract and the URDF, see [Sensor frames](#sensor-frames). |
| `collision_cylinders` | `{link: radius}`: these links get one `<cylinder>` collision instead of the mesh (see below). Used for the four mecanum wheels. |
| `build_args` | Extra arguments for `python -m sw2robot.exporter.build` (see its `--help`). Default `["--collision", "hull"]`: a convex hull per part as collision geometry instead of the full mesh. Other examples: `["--ros2"]`, `["--collision", "coacd"]`. |

The Action installs the sw2robot version recorded in `graph.json` (the one that made the extract), so the local
editor and CI always match.
