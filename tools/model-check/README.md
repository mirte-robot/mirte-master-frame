# SolidWorks model check

Read-only check of the MIRTE Master SolidWorks model, run **before** exporting the URDF.
It fails if the model has errors that would end up in (or silently change) the URDF.

## Requirements

- Windows with SolidWorks (tested with SolidWorks 2025, API 33.3)
- SolidWorks running
- Windows PowerShell 5.1 (built into Windows). Starting it from PowerShell 7 also works; the script relaunches itself.

## Run

```powershell
# from the repository root
.\tools\model-check\Check-Model.ps1
```

The script attaches to the running SolidWorks and opens `solidworks/MM-Minimal.SLDASM` if it is not open yet.
It never saves or edits anything.

**Component-name option.** If *Tools > Options > System Options > External References > Update component names when
documents are replaced* is on (the SolidWorks default, and possibly re-applied by the faculty's standard settings),
SolidWorks shows file-based names instead of the saved instance names. The check then:
1. stops with an error, changing nothing, if any open document from `solidworks/` has unsaved changes;
2. otherwise turns the option off, closes the open documents from `solidworks/`, and reopens the assembly;
3. runs the checks;
4. always turns the option back on afterwards.

Use `-NoNameOptionFix` (or `"fix_component_name_option": false`) to report the option as an error instead.

| Option | Effect |
|---|---|
| `-Strict` | Also does a forced (full) rebuild in memory and checks again. Finds problems a normal rebuild hides. **Close the assembly without saving afterwards.** |
| `-WarningsAsErrors` | Warnings also fail the check. |
| `-NoNameOptionFix` | Do not work around the component-name option; report it as an error. |
| `-Config <file>` | Use another config file. |
| `-OutDir <dir>` | Where to write the reports (default `build/model-check/`). |

Exit code: `0` passed, `1` errors found, `2` the check could not run.

Reports:
- `build/model-check/model_check.txt` -- readable report
- `build/model-check/model_check.json` -- same findings, plus the SHA-256 of every CAD file used
  (used later to prove an exported URDF belongs to exactly these CAD files)

## Checks

| Check id | Severity | What it means |
|---|---|---|
| `update-component-names-on` | error | Only with `-NoNameOptionFix`: the SolidWorks option *Update component names when documents are replaced* is on, so SolidWorks shows file-based names and URDF names change. |
| `component-name-option-overridden` | info | The option was on; the check turned it off, reopened the assembly and turned it back on. |
| `reload-failed` | error | The check could not close the documents needed to reload the saved names. |
| `expected-component-missing` | error | A component listed in `expected_components` was not found (renamed, deleted or replaced). The URDF names depend on these. |
| `unsaved-changes` | error | A document has unsaved changes; the export would not match the files on disk. |
| `needs-rebuild` | error | A document needs a rebuild. |
| `mate-error` / `mate-warning` | error / warning | A mate has an error or warning (in the top assembly or any sub-assembly). |
| `mate-misaligned` | warning | The assembly has misaligned mates. |
| `pose-mate-active` | error | A pose mate (see `pose_mates`) is not suppressed, so the arm cannot move. |
| `arm-not-in-pose` | error | The arm is not in the pose its pose mates define: the current angle between a pose mate's faces differs from the mate's angle by more than `pose_tolerance_deg`. Fix: unsuppress the pose mates, rebuild, suppress them again, save. |
| `arm-in-pose` | info | A pose mate's joint is in its pose (shows the deviation). |
| `pose-mate-missing` / `pose-mate-invalid` | error | A configured pose mate does not exist, or is not an angle mate between two entities. |
| `pose-not-checked` | warning | A pose mate's faces could not be read, so its pose was not checked. |
| `mate-suppressed` | warning | A mate is suppressed and not listed in `allowed_suppressed_mates`. |
| `rebuild-error` / `rebuild-warning` | error / warning | An item in SolidWorks' *What's Wrong* list, in any assembly or part. |
| `component-file-missing` | error | A component's file cannot be found. |
| `component-not-loaded` | error | A component is not loaded. |
| `component-lightweight` | warning | A component is lightweight; its features are not checked. |
| `component-suppressed` | warning | A component is suppressed and not listed in `allowed_suppressed_components`. |
| `component-over-constrained` | error | A component is over-constrained or has no valid solution. |
| `component-floating` | error | A component has no mates and is not fixed (pattern and mirror instances are skipped). |
| `wrong-document-open` | error | A same-named assembly from another folder is open. |
| `file-outside-repo` | warning | A CAD file used by the assembly is outside this repository. |

## Config (`model-check.config.json`)

| Key | Meaning |
|---|---|
| `assembly` | Assembly to check, relative to the repository root. |
| `solidworks_api_dir` | Folder with `SolidWorks.Interop.sldworks.dll` / `swconst.dll`. |
| `fix_component_name_option` | Work around the component-name option (default `true`, see above). |
| `expected_components` | Component paths that must exist, as SolidWorks shows them (`arm-1/shoulder_lift-3`). |
| `pose_mates` | Angle mates that define the arm's upright reference pose, as `<file>:<mate name>`. They must be suppressed, and the arm must be in the pose they define. |
| `pose_tolerance_deg` | Allowed deviation from that pose, in degrees (default 0.1). |
| `allowed_suppressed_mates` | Other suppressed mates that are intentional, as `<file>:<mate name>`. |
| `allowed_suppressed_components` | Suppressed components that are intentional (component path). |
| `allowed_unmated_components` | Unmated, unfixed components that are intentional, as `<file>:<component name>`. |

When you rename or replace a component on purpose, update `expected_components` in the same commit.
