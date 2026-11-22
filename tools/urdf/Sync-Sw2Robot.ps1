<#
.SYNOPSIS
  Update the committed sw2robot extract (sw2robot/) from the sw2robot editor, so the GitHub Action can build the URDF.

.DESCRIPTION
  The GitHub Action cannot run SolidWorks, so the sw2robot *extract* (kinematic graph + meshes) is made here and
  committed. The Action then builds the URDF / xacro from it (tools/urdf/build_urdf.py).

  Default (no switches):
    1. Puts the repository's joint config (sw2robot/<robot>.joints.yaml) into the editor's package folder
       (%TEMP%\sw2robot\output\<robot>), so you start from the committed joint settings.
    2. Starts the sw2robot editor (sw2robot-web.exe). Extract the assembly there again if the CAD changed
       (file browser / path bar), fix the joints, then CLOSE THE EDITOR'S CONSOLE WINDOW.
    3. Imports the result into sw2robot/ (same as -ImportOnly).

  Import:
    - copies graph.json + meshes into sw2robot/<robot>/ and the joint config to sw2robot/<robot>.joints.yaml
    - makes the absolute paths in it repository-relative and removes the user name from the meshes
      (the repository is public)
    - writes sw2robot/<robot>.sources.json with the SHA-256 of every SolidWorks file, which the Action uses to
      detect a CAD change without a new extract

  Exit code: 0 = OK, 1 = check failed / nothing imported, 2 = could not run.

.PARAMETER ImportOnly
  Do not start the editor; only import the editor's package folder.

.PARAMETER FromRepo
  Start the editor on the committed extract instead of the editor's own package folder (to change only joints,
  without SolidWorks). Replaces the editor's package folder with a copy of sw2robot/<robot>/.

.PARAMETER Check
  Only check whether the committed extract still matches the SolidWorks files (what the Action checks).

.PARAMETER PackageDir
  The editor's package folder (default %TEMP%\sw2robot\output\<robot_name>).

.PARAMETER Force
  Import even when SolidWorks files are newer than the extract.
#>
param(
  [switch]$ImportOnly,
  [switch]$FromRepo,
  [switch]$Check,
  [string]$PackageDir,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$cfg = Get-Content -LiteralPath (Join-Path $here 'urdf.config.json') -Raw | ConvertFrom-Json

$name = $cfg.robot_name
$swDir = Join-Path $repo $(if ($cfg.sw2robot_dir) { $cfg.sw2robot_dir } else { 'sw2robot' })
$cadDir = Join-Path $repo $(if ($cfg.cad_dir) { $cfg.cad_dir } else { 'solidworks' })
$extractDir = Join-Path $swDir $name
$jointsRepo = Join-Path $swDir "$name.joints.yaml"
$sourcesJson = Join-Path $swDir "$name.sources.json"
$editorRoot = Join-Path $env:TEMP 'sw2robot\output'
if (-not $PackageDir) { $PackageDir = Join-Path $editorRoot $name }
$PackageDir = [System.IO.Path]::GetFullPath($PackageDir)
$utf8 = New-Object System.Text.UTF8Encoding $false

# Shared read, so files SolidWorks has open can still be hashed.
function Get-Sha256([string]$path) {
  $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() } finally { $sha.Dispose() }
  } finally { $fs.Dispose() }
}

function Get-YamlContent([string]$path) {
  (Get-Content -LiteralPath $path | ForEach-Object { ($_ -replace '\s+#.*$', '' -replace '^\s*#.*$', '').TrimEnd() } |
    Where-Object { $_ }) -join "`n"
}

# SolidWorks parts / assemblies that are (or will be) in git: tracked + untracked-not-ignored. Same set the Action sees.
function Get-CadFiles {
  $rel = $null
  try {
    $rel = & git -C $repo -c core.quotepath=off ls-files --cached --others --exclude-standard --($cadDir.Substring($repo.Length + 1)) 2>$null
    if ($LASTEXITCODE -ne 0) { $rel = $null }
  } catch { $rel = $null }
  if ($null -eq $rel) {
    $rel = Get-ChildItem -LiteralPath $cadDir -Recurse -File | ForEach-Object { $_.FullName.Substring($repo.Length + 1) }
  }
  $rel | ForEach-Object { $_.Replace('\', '/') } |
    Where-Object { $_ -match '\.(sldprt|sldasm)$' -and (Split-Path $_ -Leaf) -notlike '~$*' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $repo $_) } | Sort-Object -Unique
}

function Get-CadHashes {
  $h = [ordered]@{}
  foreach ($f in (Get-CadFiles)) { $h[$f] = Get-Sha256 (Join-Path $repo $f) }
  $h
}

function Find-Editor {
  $p = [Environment]::ExpandEnvironmentVariables("$($cfg.editor_exe)")
  if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  $c = Get-Command 'sw2robot-web' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# ---- -Check ---------------------------------------------------------------------------------------------------------
if ($Check) {
  if (-not (Test-Path -LiteralPath $sourcesJson)) { Write-Host "No $sourcesJson yet: run this script to import an extract." -ForegroundColor Red; exit 1 }
  $rec = (Get-Content -LiteralPath $sourcesJson -Raw | ConvertFrom-Json).files
  $recH = @{}; foreach ($p in $rec.PSObject.Properties) { $recH[$p.Name] = $p.Value }
  $cur = Get-CadHashes
  $bad = @()
  foreach ($k in $cur.Keys) {
    if (-not $recH.ContainsKey($k)) { $bad += "added:   $k" } elseif ($recH[$k] -ne $cur[$k]) { $bad += "changed: $k" }
  }
  foreach ($k in $recH.Keys) { if (-not $cur.Contains($k)) { $bad += "removed: $k" } }
  if ($bad) {
    Write-Host 'The SolidWorks model changed since the last extract; the GitHub Action will fail:' -ForegroundColor Red
    $bad | Sort-Object | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Run .\tools\urdf\Sync-Sw2Robot.ps1, extract the assembly again in the editor, and commit sw2robot/.'
    exit 1
  }
  Write-Host "OK: the extract matches all $($cur.Count) SolidWorks files." -ForegroundColor Green
  exit 0
}

# ---- editor ---------------------------------------------------------------------------------------------------------
if (-not $ImportOnly) {
  $editor = Find-Editor
  if (-not $editor) {
    Write-Host 'sw2robot editor (sw2robot-web.exe) not found. Install it:' -ForegroundColor Red
    Write-Host '  powershell -ExecutionPolicy ByPass -c "irm https://jsk-ros-pkg.github.io/solidworks_urdf_exporter2/install.ps1 | iex"'
    Write-Host "or set editor_exe in tools\urdf\urdf.config.json."
    exit 2
  }

  if ($FromRepo) {
    if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'graph.json'))) { Write-Host "No committed extract in $extractDir." -ForegroundColor Red; exit 2 }
    if (Test-Path -LiteralPath $PackageDir) { Remove-Item -LiteralPath $PackageDir -Recurse -Force }
    Copy-Item -LiteralPath $extractDir -Destination $PackageDir -Recurse
    # the editor resolves the source assembly by absolute path
    $g = Join-Path $PackageDir 'graph.json'
    $jsonRepo = ($repo.TrimEnd('\') + '\').Replace('\', '\\')
    $t = [IO.File]::ReadAllText($g)
    $cadName = [regex]::Escape((Split-Path $cadDir -Leaf))
    $t = [regex]::Replace($t, '"(' + $cadName + '\\\\[^"]*)"', { param($m) '"' + $jsonRepo + $m.Groups[1].Value + '"' })
    [IO.File]::WriteAllText($g, $t, $utf8)
    if (-not (Test-Path -LiteralPath (Join-Path $PackageDir "urdf\$name.urdf"))) {
      # older imports left urdf/ out; the editor refuses a package without it, so build it if sw2robot is installed
      $py = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($py) { & $py.Source -m sw2robot.exporter.build $PackageDir --config $jointsRepo 2>&1 | Select-Object -Last 3 }
      if (-not (Test-Path -LiteralPath (Join-Path $PackageDir "urdf\$name.urdf"))) {
        Write-Host "No urdf\$name.urdf in the committed extract, and it could not be built (pip install sw2robot)." -ForegroundColor Red
        Write-Host 'Extract the assembly again in the editor instead (run this script without -FromRepo).'
        exit 2
      }
    }
  }
  New-Item -ItemType Directory -Force $PackageDir | Out-Null

  # Start from the repository's joint config (the source of truth); keep the editor's old one as a backup.
  $pkgJoints = Join-Path $PackageDir "$name.joints.yaml"
  if (Test-Path -LiteralPath $jointsRepo) {
    if ((Test-Path -LiteralPath $pkgJoints) -and ((Get-YamlContent $pkgJoints) -ne (Get-YamlContent $jointsRepo))) {
      Copy-Item -LiteralPath $pkgJoints -Destination "$pkgJoints.bak" -Force
      Write-Host "The editor's joint config differed from the repository's; saved it as $pkgJoints.bak" -ForegroundColor Yellow
    }
    Copy-Item -LiteralPath $jointsRepo -Destination $pkgJoints -Force
  }

  $edArgs = @('--root', "`"$(Split-Path $PackageDir)`"")
  if (Test-Path -LiteralPath (Join-Path $PackageDir 'graph.json')) { $edArgs += "`"$PackageDir`"" }
  Write-Host ''
  Write-Host 'Starting the sw2robot editor.' -ForegroundColor Cyan
  Write-Host "  - CAD changed? Extract again: open $(Join-Path $repo $cfg.assembly) via the file browser / path bar."
  Write-Host '  - Check the joints (t = fixed <-> movable). New parts get a guessed joint type.'
  Write-Host '  - When done, CLOSE THE EDITOR CONSOLE WINDOW; the result is then imported into sw2robot/.' -ForegroundColor Cyan
  $p = Start-Process -FilePath $editor -ArgumentList $edArgs -PassThru
  $p.WaitForExit()
  Write-Host 'Editor closed.'
}

# ---- import ---------------------------------------------------------------------------------------------------------
$graph = Join-Path $PackageDir 'graph.json'
if (-not (Test-Path -LiteralPath $graph)) {
  Write-Host "Nothing to import: no extract in $PackageDir (extract the assembly in the editor first)." -ForegroundColor Red
  exit 1
}
$g = [IO.File]::ReadAllText($graph) | ConvertFrom-Json
$problems = @()
if ($g.robot_name -ne $name) { $problems += "graph.json is for robot '$($g.robot_name)', expected '$name'" }
$asmFull = [IO.Path]::GetFullPath((Join-Path $repo $cfg.assembly))
$src = "$($g.source_assembly)"
if ($src -and -not [IO.Path]::IsPathRooted($src)) { $src = Join-Path $repo $src }
if ($src -and ([IO.Path]::GetFullPath($src) -ne $asmFull)) { $problems += "extract is of $($g.source_assembly), expected $asmFull" }
$missing = @($g.components | Where-Object { $_.mesh_file } | ForEach-Object { $_.mesh_file } | Sort-Object -Unique |
  Where-Object { -not (Test-Path -LiteralPath (Join-Path $PackageDir $_)) })
if ($missing) { $problems += "$($missing.Count) meshes listed in graph.json are missing (incomplete extract?), e.g. $($missing[0])" }
$graphTime = (Get-Item -LiteralPath $graph).LastWriteTimeUtc
$newer = @(Get-CadFiles | Where-Object { (Get-Item -LiteralPath (Join-Path $repo $_)).LastWriteTimeUtc -gt $graphTime })
if ($newer -and -not $Force) {
  $problems += "these SolidWorks files were saved after the extract ($($graphTime.ToLocalTime())), extract again " +
    "(or use -Force if only their timestamps changed, e.g. after a git checkout): $($newer -join ', ')"
}
if ($problems) {
  Write-Host 'Not imported:' -ForegroundColor Red
  $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}

# Copy into a staging folder first, so a failure leaves sw2robot/ untouched.
$stage = "$extractDir.import"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
# urdf/ is kept: the editor only opens a package that has urdf/<name>.urdf (needed for -FromRepo).
$skip = @('CMakeLists.txt', 'package.xml', 'launch', 'config')
Get-ChildItem -LiteralPath $PackageDir -Force | Where-Object {
  $skip -notcontains $_.Name -and $_.Name -notlike '*.joints.yaml*' -and $_.Name -notlike '*.bak'
} | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse }
# the editor's mesh cache is local only (git-ignored); the build does not need it
$meshCache = Join-Path $stage 'meshes\.mesh_cache'
if (Test-Path -LiteralPath $meshCache) { Remove-Item -LiteralPath $meshCache -Recurse -Force }

# Absolute paths -> repository-relative (the repository is public; the Action does not need them).
$jsonRepo = [regex]::Escape(($repo.TrimEnd('\') + '\').Replace('\', '\\'))
$textFiles = Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { $_.Extension -in '.json', '.yaml', '.yml' }
foreach ($f in $textFiles) {
  $t = [IO.File]::ReadAllText($f.FullName)
  $n = [regex]::Replace($t, $jsonRepo, '', 'IgnoreCase')
  $n = [regex]::Replace($n, [regex]::Escape($repo.TrimEnd('\') + '\'), '', 'IgnoreCase')
  if ($n -ne $t) { [IO.File]::WriteAllText($f.FullName, $n, $utf8) }
  $left = [regex]::Matches($n, '[A-Za-z]:(\\\\|\\|/)[^"\r\n]*') | Select-Object -First 3
  if ($left) {
    Remove-Item -LiteralPath $stage -Recurse -Force
    Write-Host "Not imported: $($f.Name) still contains absolute paths outside the repository:" -ForegroundColor Red
    $left | ForEach-Object { Write-Host "  $($_.Value)" }
    exit 1
  }
}

# The .3dxml meshes record the Windows user name as <Author>; blank it.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
foreach ($f in (Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.3dxml')) {
  $zip = [IO.Compression.ZipFile]::Open($f.FullName, [IO.Compression.ZipArchiveMode]::Update)
  try {
    foreach ($e in @($zip.Entries | Where-Object { $_.FullName -like '*.3dxml' })) {
      $r = New-Object IO.StreamReader($e.Open()); $t = $r.ReadToEnd(); $r.Dispose()
      $n = $t -replace '<Author>[^<]*</Author>', '<Author></Author>'
      if ($n -ne $t) {
        $entryName = $e.FullName; $e.Delete()
        $w = New-Object IO.StreamWriter($zip.CreateEntry($entryName).Open(), $utf8); $w.Write($n); $w.Dispose()
      }
    }
  } finally { $zip.Dispose() }
}

# A full extract writes every .3dxml again, and the zip bytes differ each time (compression) even when nothing in it
# changed. Keep the existing file when every entry is identical, so git only shows the meshes that really changed.
function Get-ZipContentHash([string]$path) {
  $zip = [IO.Compression.ZipFile]::OpenRead($path)
  try {
    $sha = [Security.Cryptography.SHA256]::Create()
    $parts = foreach ($e in ($zip.Entries | Sort-Object FullName)) {
      $s = $e.Open(); try { $h = [BitConverter]::ToString($sha.ComputeHash($s)) } finally { $s.Dispose() }
      "$($e.FullName)=$h"
    }
    return ($parts -join ';')
  } finally { $zip.Dispose() }
}
$keptMeshes = 0
foreach ($f in (Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.3dxml')) {
  $old = Join-Path $extractDir $f.FullName.Substring($stage.Length + 1)
  if (-not (Test-Path -LiteralPath $old)) { continue }
  try { $same = (Get-ZipContentHash $old) -eq (Get-ZipContentHash $f.FullName) } catch { $same = $false }
  if ($same) { Copy-Item -LiteralPath $old -Destination $f.FullName -Force; $keptMeshes++ }
}
if ($keptMeshes) { Write-Host "Kept $keptMeshes unchanged .3dxml file(s) as they were (same contents)." }

# Same graph.json as committed = no new extract (e.g. -FromRepo with only joint edits): keep the recorded CAD hashes,
# otherwise a CAD change since the last extract would be hidden.
$oldGraph = Join-Path $extractDir 'graph.json'
$reExtracted = -not ((Test-Path -LiteralPath $oldGraph) -and (Test-Path -LiteralPath $sourcesJson) -and
  ((Get-Sha256 $oldGraph) -eq (Get-Sha256 (Join-Path $stage 'graph.json'))))

# Hash before touching sw2robot/, so a failure leaves it unchanged.
try {
  if ($reExtracted) { $hashes = Get-CadHashes }
} catch {
  Remove-Item -LiteralPath $stage -Recurse -Force
  Write-Host "Not imported: could not hash the SolidWorks files: $($_.Exception.Message)" -ForegroundColor Red
  exit 2
}

# OneDrive / virus scanners briefly lock freshly written files: retry instead of leaving a half-done import.
function Invoke-Retry([scriptblock]$action, [string]$what) {
  for ($i = 1; ; $i++) {
    try { & $action; return } catch {
      if ($i -ge 15) {
        Write-Host "Not imported: $what failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Close Explorer windows / editors in sw2robot\ and run: .\tools\urdf\Sync-Sw2Robot.ps1 -ImportOnly"
        exit 2
      }
      Start-Sleep -Seconds 2
    }
  }
}
if (Test-Path -LiteralPath $extractDir) {
  Invoke-Retry { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction Stop } "removing $extractDir"
}
Invoke-Retry { Rename-Item -LiteralPath $stage -NewName (Split-Path $extractDir -Leaf) -ErrorAction Stop } "renaming $stage"

$pkgJoints = Join-Path $PackageDir "$name.joints.yaml"
$jointsChanged = $false
if (Test-Path -LiteralPath $pkgJoints) {
  $jointsChanged = -not (Test-Path -LiteralPath $jointsRepo) -or ((Get-Sha256 $pkgJoints) -ne (Get-Sha256 $jointsRepo))
  Copy-Item -LiteralPath $pkgJoints -Destination $jointsRepo -Force
}

if ($reExtracted) {
  $sources = [ordered]@{
    tool = 'mirte-sw2robot-sync'
    version = 1
    note = 'SHA-256 of the SolidWorks files the sw2robot extract was made from. Written by tools/urdf/Sync-Sw2Robot.ps1.'
    extracted_utc = $graphTime.ToString('o')
    extractor = "$($g.source.extractor)"
    assembly = $cfg.assembly
    files = $hashes
  }
  [IO.File]::WriteAllText($sourcesJson, ($sources | ConvertTo-Json -Depth 4), $utf8)
} else {
  $hashes = @((Get-Content -LiteralPath $sourcesJson -Raw | ConvertFrom-Json).files.PSObject.Properties)
  Write-Host 'Extract unchanged (no new extract); kept the recorded SolidWorks hashes.'
}

$size = (Get-ChildItem -LiteralPath $extractDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ''
Write-Host ("Imported: {0} ({1:N1} MB), joint config {2}, {3} SolidWorks file hashes." -f
  $extractDir.Substring($repo.Length + 1), $size, $(if ($jointsChanged) { 'CHANGED' } else { 'unchanged' }), $hashes.Count) -ForegroundColor Green
Write-Host 'Review and commit:'
Write-Host "  git status -- sw2robot"
Write-Host "  git diff -- `"$($jointsRepo.Substring($repo.Length + 1))`""
Write-Host "  git add sw2robot && git commit -m `"Update sw2robot extract`""
exit 0
