# MIRTE Master frame

SolidWorks model of the MIRTE Master (`solidworks/`), with the part exports (`exports/`) and the sw2robot extract for the
URDF (`sw2robot/`). GitHub builds the URDF and publishes the parts from these, but it cannot run SolidWorks, so
`exports/` and `sw2robot/` must be updated on your PC before you push. Otherwise the GitHub Action fails.

**Current working version: `solidworks/MM-Minimal.SLDASM`.** The exports and the URDF are made from this assembly.

Run all commands from the repository root (PowerShell).

## Before you push

### 1. You changed the SolidWorks model (parts, assemblies, configurations, colours)

1. Save everything in SolidWorks and keep `MM-Minimal.SLDASM` open.
2. Export the parts (STEP / STL / DXF):
   `.\tools\export\Export-Parts.ps1`
3. Update the URDF extract:
   `.\tools\urdf\Sync-Sw2Robot.ps1`
   - In the editor, extract `solidworks/MM-Minimal.SLDASM` again, and check the joints (new parts get a guessed joint type).
   - Press F5 in the editor's browser tab if a changed part still looks old.
   - Close the editor's console window; the script then copies the result into `sw2robot/`.
4. Stage and check:
   `git add solidworks exports sw2robot`
   `python tools/check_before_push.py --staged`
5. Commit and push.

### 2. You only changed the URDF in sw2robot (joint types, axes, limits, names)

No SolidWorks needed.

1. Open the editor on the committed extract:
   `.\tools\urdf\Sync-Sw2Robot.ps1 -FromRepo`
2. Make your changes, then close the editor's console window.
3. Stage and check:
   `git add sw2robot`
   `python tools/check_before_push.py --staged`
4. Commit and push.

Tip: `python tools/check_before_push.py --install-hook` runs the check automatically on every `git push`.

More detail: [`tools/export`](tools/export/README.md) (part exports), [`tools/urdf`](tools/urdf/README.md) (URDF).


## License

The SolidWorks files in the solidworks/ folder are licensed under the SolidWorks Education Edition License.

The hardware artifacts in the export/ folder (eg. STL, STEP and DXF) are licensed under a CERN-OHL-S license.