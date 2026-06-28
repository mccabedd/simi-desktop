#Requires -Version 5.1
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$appName = 'SIMI-desktop'
$ps1     = Join-Path $here "$appName.ps1"
$exe     = Join-Path $here "$appName.exe"
$iconFile = Join-Path $here 'Assets\Icons\simi-desktop.ico'

Write-Host 'Checking for PS2EXE...'
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing PS2EXE (this takes a moment)...'
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

Write-Host 'Compiling exe...'
Invoke-ps2exe `
    -inputFile  $ps1 `
    -outputFile $exe `
    -iconFile   $iconFile `
    -noConsole `
    -title       'SIMI-desktop' `
    -description 'Simple Image Metadata Inspector — standalone ComfyUI PNG metadata viewer' `
    -version     '1.4.0.0'

Write-Host 'Building portable folder...'
$outDir = Join-Path $here "$appName-Portable"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outDir 'Assets')        | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outDir 'Assets\Icons')  | Out-Null

# Root: exe only
Copy-Item $exe -Destination $outDir

# Assets: helper script
Copy-Item (Join-Path $here 'Assets\ComfyUI-PNG-Meta.ps1') -Destination (Join-Path $outDir 'Assets')

# Assets\Icons: all icon files
$icons = @(
    'close.png','collapse.png','copy-icon.png','expand.png',
    'image.png','minimize.png','next.png','open.png',
    'pin.png','previous.png',
    'layout-h.png','layout-v.png',
    'simi-desktop-blue.ico','simi-desktop.ico'
)
foreach ($f in $icons) {
    $src = Join-Path $here "Assets\Icons\$f"
    if (Test-Path $src) { Copy-Item $src -Destination (Join-Path $outDir 'Assets\Icons') }
    else { Write-Warning "Missing icon: $f" }
}

$zipPath = Join-Path $here "$appName-Portable.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath

Write-Host ''
Write-Host "Done! Portable zip: $zipPath"
Write-Host "Extract it anywhere (keeping the Assets folder alongside the exe) and run $appName.exe"
