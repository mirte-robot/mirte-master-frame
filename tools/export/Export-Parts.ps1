<#
.SYNOPSIS
  Export STL, STEP and DXF manufacturing files for the custom parts of the MIRTE Master assembly.

.DESCRIPTION
  Attaches to the running SolidWorks (opening the assembly if needed), walks every resolved part in the assembly and
  sorts each (part file, configuration) into:
    print  -> STEP + STL   (custom parts, the default)
    laser  -> STEP + DXF   (sheet metal parts with a flat pattern, and parts listed in laser_files)
    none   -> nothing      (purchased folders, exclude_files, components excluded from the BOM)
  A custom property (default name 'Export', value print | laser | none) on the part or configuration overrides the rules.

  Each output file name starts with the part's group (base_ / arm_ / gripper_, see 'groups' in the config), based on
  the sub-assembly the part sits in.

  Writes to -OutDir: stl/, step/, dxf/, export_report.txt and export_manifest.json (with SHA-256 of every source
  part, every assembly and every output file). The output is committed (exports/), so the GitHub Action can check it
  against the SolidWorks files and publish it (tools/export/check_exports.py).
  Parts whose source file did not change keep their previous output files byte for byte (STEP / STL headers carry a
  timestamp), so a re-export only changes the files of parts that really changed. -Force re-exports everything.
  Exit code: 0 = all exported, 1 = some exports failed, 2 = the export could not run.

.PARAMETER Config
  Config file (default: export.config.json next to this script).

.PARAMETER OutDir
  Output folder (default: out_dir in the config, i.e. <repo>/exports). Old STL/STEP/DXF files in it are removed first.

.PARAMETER Force
  Write every output file fresh, also for parts whose source did not change.

.PARAMETER ListOnly
  Only show which parts would be exported and how; export nothing.
#>
param(
  [string]$Config,
  [string]$OutDir,
  [switch]$ListOnly,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# The SolidWorks interop needs Windows PowerShell 5.1 (.NET Framework). Relaunch if started from PowerShell 7.
if ($PSVersionTable.PSEdition -eq 'Core') {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $argList += "-$k" } }
    else { $argList += "-$k"; $argList += "$v" }
  }
  & powershell.exe @argList
  exit $LASTEXITCODE
}

$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
if (-not $Config) { $Config = Join-Path $here 'export.config.json' }
$OutDir0 = $OutDir
$OutDir = $null
$prevDir = $null

# Put the previous run's output files back (used when the run stops before it exported anything).
function Restore-Previous {
  if (-not $prevDir -or -not (Test-Path $prevDir)) { return }
  if (Test-Path $OutDir) {
    Get-ChildItem $OutDir -Recurse -File | Where-Object { $_.Extension -in '.stl', '.step', '.dxf' } | Remove-Item -Force
  }
  foreach ($f in @(Get-ChildItem $prevDir -Recurse -File)) {
    $dst = Join-Path $repo $f.FullName.Substring($prevDir.Length + 1)
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
  }
  Remove-Item -LiteralPath $prevDir -Recurse -Force
  Write-Host "The previous export files were put back; $OutDir is unchanged."
}

try {
  $cfg = Get-Content $Config -Raw | ConvertFrom-Json
  if ($OutDir0) { $OutDir = $OutDir0 } else { $OutDir = Join-Path $repo $(if ($cfg.out_dir) { $cfg.out_dir } else { 'exports' }) }
  $OutDir = [System.IO.Path]::GetFullPath($OutDir)

  $swDir = $cfg.solidworks_api_dir
  if (-not $swDir) { $swDir = 'C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\redist' }
  $refs = @((Join-Path $swDir 'SolidWorks.Interop.sldworks.dll'), (Join-Path $swDir 'SolidWorks.Interop.swconst.dll'))
  foreach ($r in $refs) {
    if (-not (Test-Path $r)) { throw "SolidWorks interop not found: $r (set solidworks_api_dir in the config)" }
    Add-Type -Path $r
  }
  Add-Type -Path (Join-Path $here 'SwExport.cs') -ReferencedAssemblies $refs

  $opt = New-Object MirteExport.ExportOptions
  $opt.RepoRoot = $repo
  $opt.AssemblyPath = Join-Path $repo $cfg.assembly
  $opt.OutDir = $OutDir
  if ($cfg.property_name) { $opt.PropertyName = $cfg.property_name }
  $opt.PurchasedFolders = [string[]]@($cfg.purchased_folders | Where-Object { $_ })
  $opt.ExcludeFiles = [string[]]@($cfg.exclude_files | Where-Object { $_ })
  $opt.LaserFiles = [string[]]@($cfg.laser_files | Where-Object { $_ })
  $opt.PrintFiles = [string[]]@($cfg.print_files | Where-Object { $_ })
  $opt.ListOnly = [bool]$ListOnly
  if ($cfg.default_group) { $opt.DefaultGroup = $cfg.default_group }
  $gNames = @(); $gAsms = @()
  if ($cfg.groups) {
    foreach ($p in $cfg.groups.PSObject.Properties) {
      foreach ($a in @($p.Value)) { $gNames += $p.Name; $gAsms += $a }
    }
  }
  $opt.GroupNames = [string[]]$gNames
  $opt.GroupAssemblies = [string[]]$gAsms
  $oFiles = @(); $oNames = @()
  if ($cfg.group_overrides) {
    foreach ($p in $cfg.group_overrides.PSObject.Properties) { $oFiles += $p.Name; $oNames += $p.Value }
  }
  $opt.GroupOverrideFiles = [string[]]$oFiles
  if ($cfg.variants) { $opt.Variants = [string[]]@($cfg.variants) }
  $opt.GroupOverrideNames = [string[]]$oNames

  # Keep a copy of the previous run's files: to reuse them for parts that did not change, and to put them back
  # when this run stops early (otherwise an aborted run would leave exports/ empty).
  $prevManifest = $null; $prevDir = $null
  $prevPath = Join-Path $OutDir 'export_manifest.json'
  if (-not $ListOnly -and (Test-Path $OutDir)) {
    if (-not $Force -and (Test-Path $prevPath)) {
      try { $prevManifest = Get-Content $prevPath -Raw | ConvertFrom-Json } catch { $prevManifest = $null }
    }
    $prevDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mirte-export-prev-" + [guid]::NewGuid().ToString('N'))
    foreach ($f in @(Get-ChildItem $OutDir -Recurse -File | Where-Object { $_.Extension -in '.stl', '.step', '.dxf' })) {
      $dst = Join-Path $prevDir $f.FullName.Substring($repo.Length + 1)
      New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
      Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
  }

  if (-not $ListOnly -and (Test-Path $OutDir)) {
    # Remove stale exports (in every group folder) so the output only holds files from this run.
    Get-ChildItem $OutDir -Recurse -File | Where-Object { $_.Extension -in '.stl', '.step', '.dxf' } | Remove-Item -Force
    Get-ChildItem $OutDir -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
      Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item -Force
  }

  Write-Host "$(if ($ListOnly) { 'Listing' } else { 'Exporting' }) parts of $($cfg.assembly) ..."
  $res = [MirteExport.Exporter]::Run($opt)
}
catch {
  Write-Host "Export could not run: $($_.Exception.Message)" -ForegroundColor Red
  Restore-Previous
  exit 2
}

if ($res.Errors.Count -gt 0) {
  foreach ($e in $res.Errors) { Write-Host "ERROR: $e" -ForegroundColor Red }
  Restore-Previous
  exit 2
}

function Get-Sha256([string]$path) {
  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() } finally { $sha.Dispose() }
  } finally { $fs.Dispose() }
}

# SolidWorks files as git sees them (tracked + untracked-not-ignored), so the check in the Action sees the same set.
function Get-CadFiles([string]$ext) {
  $cad = 'solidworks'
  $rel = $null
  try {
    $rel = & git -C $repo -c core.quotepath=off ls-files --cached --others --exclude-standard -- $cad 2>$null
    if ($LASTEXITCODE -ne 0) { $rel = $null }
  } catch { $rel = $null }
  if ($null -eq $rel) { $rel = Get-ChildItem (Join-Path $repo $cad) -Recurse -File | ForEach-Object { $_.FullName.Substring($repo.Length + 1) } }
  $rel | ForEach-Object { $_.Replace('\', '/') } |
    Where-Object { $_ -like "*.$ext" -and (Split-Path $_ -Leaf) -notlike '~$*' -and (Test-Path -LiteralPath (Join-Path $repo $_)) } |
    Sort-Object -Unique
}

# Reuse the previous output of parts whose source, configuration, kind and SolidWorks version did not change.
$reused = 0
if ($prevManifest -and $prevDir -and "$($prevManifest.solidworks_revision)" -eq "$($res.SolidWorksRevision)") {
  foreach ($it in @($res.Items | Where-Object { $_.Kind -ne 'none' -and $_.Errors.Count -eq 0 -and $_.Outputs.Count -gt 0 })) {
    $sha = Get-Sha256 $it.Path
    $old = @($prevManifest.parts | Where-Object { $_.source -eq $it.RelPath -and $_.configuration -eq $it.Config -and
      $_.kind -eq $it.Kind -and $_.source_sha256 -eq $sha }) | Select-Object -First 1
    if (-not $old) { continue }
    $oldPaths = @($old.outputs | ForEach-Object { $_.path } | Sort-Object)
    $newPaths = @($it.Outputs | Sort-Object)
    if (($oldPaths -join '|') -ne ($newPaths -join '|')) { continue }
    if (@($oldPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $prevDir $_)) }).Count) { continue }
    foreach ($o in $oldPaths) { Copy-Item -LiteralPath (Join-Path $prevDir $o) -Destination (Join-Path $repo $o) -Force }
    $reused++
  }
}
if ($prevDir -and (Test-Path $prevDir)) { Remove-Item -LiteralPath $prevDir -Recurse -Force }

$groupOrder = @{}; $gi = 0
foreach ($g in @($opt.DefaultGroup) + @($opt.GroupNames)) { if (-not $groupOrder.ContainsKey($g)) { $groupOrder[$g] = $gi++ } }
$items = @($res.Items | Sort-Object @{ e = { @{ laser = 0; print = 1; none = 2 }[$_.Kind] } }, @{ e = { $groupOrder[$_.Group] } }, RelPath, Config)
$failed = @($items | Where-Object { $_.Kind -ne 'none' -and ($_.Errors.Count -gt 0 -or ($_.Outputs.Count -eq 0 -and -not $ListOnly)) })

$lines = @()
$lines += "MIRTE part export - $((Get-Date).ToUniversalTime().ToString('o'))"
$lines += "Assembly : $($cfg.assembly)   SolidWorks $($res.SolidWorksRevision)"
$lines += "Parts    : $(@($items | Where-Object Kind -eq 'print').Count) print (STEP+STL), $(@($items | Where-Object Kind -eq 'laser').Count) laser (STEP+DXF), $(@($items | Where-Object Kind -eq 'none').Count) not exported"
if (-not $ListOnly) { $lines += "Result   : " + $(if ($failed.Count) { "FAILED ($($failed.Count) parts with errors)" } else { 'OK' }) }
$lines += ''
foreach ($it in $items) {
  $name = $(if ($it.BaseName) { $it.BaseName } else { '-' })
  $lines += ('[{0,-5}] {1,-8} {2,-58} {3,-26} -> {4,-44} ({5})' -f $it.Kind.ToUpper(), $it.Group, $it.RelPath, $it.Config, $name, $it.Reason)
  foreach ($e in $it.Errors) { $lines += "        ! $e" }
}
foreach ($n in $res.Notes) { $lines += ''; $lines += "NOTE: $n" }

if (-not $ListOnly) {
  $manifest = [ordered]@{
    tool = 'mirte-part-export'
    version = 1
    time_utc = (Get-Date).ToUniversalTime().ToString('o')
    assembly = $cfg.assembly
    solidworks_revision = $res.SolidWorksRevision
    git_commit = "$(try { & git -C $repo rev-parse HEAD 2>$null } catch { '' })"
    passed = ($failed.Count -eq 0)
    note = 'Made by tools/export/Export-Parts.ps1. The GitHub Action (tools/export/check_exports.py) fails when an exported part or any assembly changed after this export.'
    assemblies = $($h = [ordered]@{}; foreach ($a in (Get-CadFiles 'sldasm')) { $h[$a] = Get-Sha256 (Join-Path $repo $a) }; $h)
    parts = @($items | ForEach-Object {
      [ordered]@{
        source = $_.RelPath
        source_sha256 = (Get-Sha256 $_.Path)
        configuration = $_.Config
        group = $_.Group
        kind = $_.Kind
        variant = [bool]$_.Variant
        reason = $_.Reason
        components = @($_.Components)
        outputs = @($_.Outputs | ForEach-Object { [ordered]@{ path = $_; sha256 = (Get-Sha256 (Join-Path $repo $_)) } })
        errors = @($_.Errors)
      }
    })
  }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $OutDir 'export_manifest.json')
  $lines | Set-Content -Encoding UTF8 (Join-Path $OutDir 'export_report.txt')
}

foreach ($l in $lines) {
  $color = 'Gray'
  if ($l -like '*! *') { $color = 'Red' } elseif ($l -like '`[LASER*') { $color = 'Cyan' } elseif ($l -like '`[PRINT*') { $color = 'Green' } elseif ($l -like 'Result*') { $color = $(if ($failed.Count) { 'Red' } else { 'Green' }) }
  Write-Host $l -ForegroundColor $color
}
if (-not $ListOnly) {
  if ($reused) { Write-Host "`n$reused unchanged parts kept their previous files (use -Force to re-export them)." }
  Write-Host "`nOutput: $OutDir"
  Write-Host "Commit it: git add `"$((Resolve-Path -LiteralPath $OutDir).Path.Substring($repo.Length + 1))`"; the GitHub Action checks and publishes it."
}
if ($failed.Count -gt 0 -and -not $ListOnly) { exit 1 } else { exit 0 }
