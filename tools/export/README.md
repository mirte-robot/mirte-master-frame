# Part export (STL / STEP / DXF)

Exports the manufacturing files for the custom parts of the MIRTE Master assembly, straight from SolidWorks.
For the URDF see [`tools/urdf`](../urdf/README.md).

## Requirements

Same as the [model check](../model-check/README.md): Windows, SolidWorks running (tested with SolidWorks 2025, API 33.3),
Windows PowerShell 5.1 (the script relaunches itself when started from PowerShell 7).

## Run

```powershell
# from the repository root
.\tools\model-check\Check-Model.ps1        # optional, recommended first
.\tools\export\Export-Parts.ps1 -ListOnly  # show what would be exported, export nothing
.\tools\export\Export-Parts.ps1            # export
```

Output in `exports/` (old STL/STEP/DXF files there are removed first). Parts whose SolidWorks file did not change
keep their previous files byte for byte, so git only sees the parts that really changed; `-Force` re-exports all.

**Commit `exports/` and push.** SolidWorks can't run on GitHub, so the GitHub Action
(`.github/workflows/urdf.yml`, job `parts`) does not export; it runs `tools/export/check_exports.py`. That
check fails when an exported part, or any assembly, changed after the export, or when an output file is missing or was
edited by hand. Otherwise it publishes `exports/` as the `parts` artifact, and in the release zip for a `v*` tag. So:
after changing the CAD (geometry *or* colours, since the check compares file hashes), run the export again before you
push.

Check before pushing, on exactly what GitHub gets (the committed files, without line-ending conversion):
`python tools/check_before_push.py` (last commit), `--staged` (what is staged), or `--install-hook` to run it
automatically on every `git push`. `.gitattributes` keeps `exports/` byte for byte (`-text`), so the STEP / DXF hashes
match on GitHub.

| Folder | Contents |
|---|---|
| `step/` | STEP (AP214) of every exported part, printed and laser cut |
| `stl/`  | Binary STL (mm, fine quality, part coordinates) of every 3D-printed part |
| `step/variants/`, `stl/variants/` | Alternative versions of a part that the assembly does not use (see [Variants](#variants)) |
| `dxf/`  | DXF (mm) of every laser-cut plate |
| `export_report.txt` | Which part went where, and why |
| `export_manifest.json` | Same, plus the SHA-256 of every source part, assembly and output file |

One file per part **configuration** that the assembly uses, named `<group>_<file>`, or `<group>_<file>-<configuration>`
when several configurations of one part file are used, e.g. `arm_linkages-forearm.STEP`, `base_Lidar-Mount.STL`,
`gripper_link.STL`.

### Group prefix: base / arm / gripper

A part gets the group of the **sub-assembly it sits in** (the nearest one listed under `groups` in the config):
everything inside `arm_assembly.SLDASM` gets `arm_`, everything inside `underactuated_girpper_assembly.SLDASM` gets
`gripper_`, and everything else (placed directly in MM-Minimal) gets `base_`. The folder a part file is saved in does
not matter. For example, `Arm/Camera-Mount.SLDPRT` is placed directly in MM-Minimal, so it becomes `base_Camera-Mount`.
To give a part another group anyway, add it to `group_overrides`, e.g. `"solidworks/Arm/Camera-Mount.SLDPRT": "arm"`.

Exit code: `0` all exported, `1` some parts failed (see the report), `2` the export could not run.

## Which parts are exported

Every resolved, unsuppressed part in the assembly is sorted per configuration. The first matching rule wins:

1. Custom property **`Export`** on the part configuration, or on the part (*File > Properties*): `print`, `laser` or `none`.
2. Component is *excluded from the bill of materials* → `none`.
3. Listed in `exclude_files` → `none`.
4. Listed in `print_files` → `print`.
5. Listed in `laser_files` → `laser`.
6. In one of the `purchased_folders` (bought or reference parts, e.g. `solidworks/Misc Parts`) → `none`.
7. Sheet-metal part (has a flat pattern) → `laser`.
8. Anything else → `print`.

| Kind | Files |
|---|---|
| `print` | STEP + STL |
| `laser` | STEP + DXF. Sheet metal: the flat pattern. Other plates: the outline and holes of the largest planar face. |
| `none`  | nothing |

List entries are repository paths, optionally with a configuration: `"solidworks/Frame/Plate v01.SLDPRT"` (all
configurations) or `"solidworks/Frame/Plate v01.SLDPRT:Top Plate"` (one configuration).

When you add a new part, run with `-ListOnly` and check it lands in the right group. If it doesn't, either add an
`Export` custom property to the part (the setting then travels with the part) or add it to the config.

## Variants

Some parts have configurations for other hardware that replace the standard part, e.g. a left side panel for a
Raspberry Pi 4B instead of the Orange Pi 3B, or a right side panel without the Ethernet port. The assembly uses one of
them; the others are listed under `variants` in the config and exported too, always as STEP + STL, to `step/variants/`
and `stl/variants/`, named `<group>_<file>-<configuration>`, e.g. `base_Left-Sidepanel-Module-RPI4B.STL`.

An entry `"solidworks/Frame/Left-Sidepanel-Module.SLDPRT"` exports every configuration of that part that the assembly
does not use, so a new configuration is picked up automatically; `"...SLDPRT:RPI4B"` exports only that one. The
configuration names are the variant names in the file names, so keep them short (the hardware, not the part name).

| Part | In the assembly | Variants |
|---|---|---|
| `Frame/Left-Sidepanel-Module` | OPI3Bv2.1 | RPI4B, OPI3Bv1.1 |
| `Frame/Right-Sidepanel-Module` | Ethernet Connector | Empty |
| `Frame/Camera-Module` | AstraMiniPro | AstraProPlus |

## Config (`export.config.json`)

| Key | Meaning |
|---|---|
| `assembly` | Assembly to export from, relative to the repository root. |
| `out_dir` | Output folder, relative to the repository root (default `exports`; committed, checked by the Action). |
| `solidworks_api_dir` | Folder with `SolidWorks.Interop.sldworks.dll` / `swconst.dll`. |
| `property_name` | Name of the override custom property (default `Export`). |
| `groups` | Group (file-name prefix) → sub-assemblies whose parts get that prefix. |
| `default_group` | Group for parts not inside any listed sub-assembly (default `base`). |
| `group_overrides` | Part (`"path"` or `"path:config"`) → group, overriding the sub-assembly rule. |
| `purchased_folders` | Folders with bought / reference parts; never exported. |
| `exclude_files` | Parts (or part configurations) never exported. |
| `laser_files` | Plates that are not sheet-metal parts but are laser cut. |
| `print_files` | Parts that are 3D printed even though another rule would say otherwise. |
| `variants` | Part configurations not used in the assembly that are exported too (STEP + STL, to `*/variants/`): `"path"` = all unused configurations, `"path:config"` = one. |

## What it changes

It never saves a CAD file. To export a configuration that is not the active one it switches the part's configuration in
memory, so the export **refuses to start if any document from `solidworks/` has unsaved changes**. Afterwards it closes
those documents without saving, reopens the assembly and every document that had a window open, and re-activates the
document you were working in. It also sets the STL/STEP export options for the run and
puts your own settings back afterwards.
