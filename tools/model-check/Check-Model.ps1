<#
.SYNOPSIS
  Read-only check of the MIRTE Master SolidWorks model before a URDF export.

.DESCRIPTION
  Attaches to the running SolidWorks (opening the assembly if needed) and checks:
  mate errors/warnings, misaligned and suppressed mates, SolidWorks "What's Wrong" rebuild
  errors in every assembly and part, missing / not-loaded / lightweight / suppressed components,
  over-constrained and floating components, unsaved changes, pending rebuilds, and that the
  component names the URDF depends on still exist.

  Writes model_check.txt and model_check.json (including SHA-256 hashes of every CAD file used)
  to -OutDir. Exit code: 0 = no errors, 1 = errors found, 2 = check could not run.

.PARAMETER Config
  Config file (default: model-check.config.json next to this script).

.PARAMETER OutDir
  Where to write the reports (default: <repo>/build/model-check).

.PARAMETER Strict
  Also run a forced (full) rebuild in memory and check again. This marks the document as
  modified: close it WITHOUT saving afterwards.

.PARAMETER WarningsAsErrors
  Treat warnings as errors (exit code 1).

.PARAMETER NoNameOptionFix
  Do not work around 'Update component names when documents are replaced' being on; report it as an error instead.
  By default the check turns the option off, closes and reopens the assembly (only if nothing has unsaved changes),
  and turns the option back on afterwards.
#>
param(
  [string]$Config,
  [string]$OutDir,
  [switch]$Strict,
  [switch]$WarningsAsErrors,
  [switch]$NoNameOptionFix
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
if (-not $Config) { $Config = Join-Path $here 'model-check.config.json' }
if (-not $OutDir) { $OutDir = Join-Path $repo 'build\model-check' }

try {
  $cfg = Get-Content $Config -Raw | ConvertFrom-Json

  $swDir = $cfg.solidworks_api_dir
  if (-not $swDir) { $swDir = 'C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\redist' }
  $refs = @((Join-Path $swDir 'SolidWorks.Interop.sldworks.dll'), (Join-Path $swDir 'SolidWorks.Interop.swconst.dll'))
  foreach ($r in $refs) {
    if (-not (Test-Path $r)) { throw "SolidWorks interop not found: $r (set solidworks_api_dir in the config)" }
    Add-Type -Path $r
  }
  Add-Type -Path (Join-Path $here 'SwModelCheck.cs') -ReferencedAssemblies $refs

  $opt = New-Object MirteModelCheck.CheckOptions
  $opt.AssemblyPath = Join-Path $repo $cfg.assembly
  $opt.ExpectedComponents = [string[]]@($cfg.expected_components)
  $opt.AllowedSuppressedMates = [string[]]@($cfg.allowed_suppressed_mates)
  $opt.AllowedSuppressedComponents = [string[]]@($cfg.allowed_suppressed_components)
  $opt.AllowedUnmatedComponents = [string[]]@($cfg.allowed_unmated_components)
  $opt.PoseMates = [string[]]@($cfg.pose_mates)
  if ($null -ne $cfg.pose_tolerance_deg) { $opt.PoseToleranceDeg = [double]$cfg.pose_tolerance_deg }
  $opt.FixNameOption = (-not $NoNameOptionFix) -and ($cfg.fix_component_name_option -ne $false)
  $opt.Strict = [bool]$Strict

  Write-Host "Checking $($cfg.assembly) ..."
  $res = [MirteModelCheck.Checker]::Run($opt)
}
catch {
  Write-Host "Model check could not run: $($_.Exception.Message)" -ForegroundColor Red
  exit 2
}

# Hash every CAD file used, so a later export can prove it came from exactly these files.
# SolidWorks keeps open files locked for writing, so open them with shared access.
function Get-Sha256([string]$path) {
  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() } finally { $sha.Dispose() }
  } finally { $fs.Dispose() }
}
$files = @()
foreach ($f in $res.Files) {
  $rel = $f
  if ($f.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) { $rel = $f.Substring($repo.Length).TrimStart('\').Replace('\', '/') }
  else { $res.Findings.Add((New-Object MirteModelCheck.Finding('warning', 'file-outside-repo', '', $f, 'CAD file is outside this repository; the export cannot be reproduced from the repo alone.'))) }
  $files += [ordered]@{ path = $rel; sha256 = (Get-Sha256 $f) }
}

$errors = @($res.Findings | Where-Object { $_.Severity -eq 'error' })
$warnings = @($res.Findings | Where-Object { $_.Severity -eq 'warning' })
$failed = ($errors.Count -gt 0) -or ($WarningsAsErrors -and $warnings.Count -gt 0)

$gitCommit = ''
try { $gitCommit = (& git -C $repo rev-parse HEAD 2>$null) } catch { }

$report = [ordered]@{
  tool = 'mirte-model-check'
  version = 1
  time_utc = (Get-Date).ToUniversalTime().ToString('o')
  assembly = $cfg.assembly
  solidworks_revision = $res.SolidWorksRevision
  git_commit = "$gitCommit"
  strict = [bool]$Strict
  name_option_overridden = [bool]$res.NameOptionChanged
  passed = -not $failed
  counts = [ordered]@{ errors = $errors.Count; warnings = $warnings.Count }
  findings = @($res.Findings | ForEach-Object { [ordered]@{ severity = $_.Severity; check = $_.Check; document = $_.Document; item = $_.Item; message = $_.Message } })
  files = $files
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $OutDir 'model_check.json')

$lines = @()
$lines += "MIRTE model check - $($report.time_utc)"
$lines += "Assembly : $($cfg.assembly)   SolidWorks $($res.SolidWorksRevision)   strict=$([bool]$Strict)"
$lines += "Files    : $($files.Count) CAD files checked"
$lines += "Result   : " + $(if ($failed) { 'FAILED' } else { 'PASSED' }) + "  ($($errors.Count) errors, $($warnings.Count) warnings)"
$lines += ''
foreach ($f in ($res.Findings | Sort-Object @{ e = { @{ error = 0; warning = 1; info = 2 }[$_.Severity] } }, Document, Item)) {
  $lines += ('[{0,-7}] {1,-28} {2,-36} {3}: {4}' -f $f.Severity.ToUpper(), $f.Check, $f.Document, $f.Item, $f.Message)
}
if ($res.NameOptionChanged) {
  $lines += ''
  $lines += "NOTE: 'Update component names when documents are replaced' was on. The check turned it off, reopened the assembly"
  $lines += '      to load the saved component names, and turned the option back on.'
}
if ($res.StrictRebuildDone) {
  $lines += ''
  $lines += 'NOTE: strict mode ran a forced rebuild. Close the assembly WITHOUT saving.'
}
$lines | Set-Content -Encoding UTF8 (Join-Path $OutDir 'model_check.txt')

foreach ($l in $lines) {
  $color = 'Gray'
  if ($l -like '`[ERROR*') { $color = 'Red' } elseif ($l -like '`[WARNING*') { $color = 'Yellow' } elseif ($l -like 'Result*') { $color = $(if ($failed) { 'Red' } else { 'Green' }) }
  Write-Host $l -ForegroundColor $color
}
Write-Host "`nReports: $OutDir"
if ($failed) { exit 1 } else { exit 0 }
