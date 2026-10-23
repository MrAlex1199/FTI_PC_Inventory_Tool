<#
.SYNOPSIS
  Build script for FTI PC Inventory Tool.
  Merges Core.ps1 + Gui.ps1 and compiles to standalone .exe via PS2EXE.

.USAGE
  powershell -ExecutionPolicy Bypass -File .\build.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ExeName = 'FTI_PC_Inventory.exe'
)
if (-not $OutputDir) {
    $OutputDir = Join-Path $PSScriptRoot 'dist'
}

$ErrorActionPreference = 'Stop'
Write-Host '===================================================' -ForegroundColor Cyan
Write-Host '  FTI PC Inventory Tool - Build & Compile to .EXE   ' -ForegroundColor White
Write-Host '===================================================' -ForegroundColor Cyan

# 1. Resolve paths
$srcCore   = Join-Path $PSScriptRoot 'src\Get-PCInventory.Core.ps1'
$srcServer = Join-Path $PSScriptRoot 'src\AppServer.ps1'
$srcHtml   = Join-Path $PSScriptRoot 'src\web\index.html'
$buildDir  = Join-Path $PSScriptRoot 'build'
$mergedFile = Join-Path $buildDir 'merged.ps1'

if (-not (Test-Path $srcCore))   { throw "Cannot find $srcCore" }
if (-not (Test-Path $srcServer)) { throw "Cannot find $srcServer" }
if (-not (Test-Path $srcHtml))   { throw "Cannot find $srcHtml" }

# 2. Check / Load ps2exe
Write-Host '[1/5] Checking ps2exe module...' -ForegroundColor Yellow
$ps2exeLoaded = $false
if (Get-Module -Name ps2exe) {
    $ps2exeLoaded = $true
} elseif (Get-Module -ListAvailable -Name ps2exe) {
    Import-Module ps2exe -ErrorAction SilentlyContinue
    $ps2exeLoaded = $true
} else {
    $tempModDir = Join-Path $env:TEMP 'Modules'
    $localMod = Join-Path $tempModDir 'ps2exe\*\ps2exe.psm1'
    $found = Resolve-Path $localMod -ErrorAction SilentlyContinue
    if ($found) {
        Import-Module $found[0].Path
        $ps2exeLoaded = $true
    } else {
        Write-Host 'Downloading ps2exe to temp folder...' -ForegroundColor Gray
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Path $tempModDir -Force | Out-Null
        Save-Module -Name ps2exe -Path $tempModDir -Force
        $found = Resolve-Path $localMod -ErrorAction SilentlyContinue
        if ($found) {
            Import-Module $found[0].Path
            $ps2exeLoaded = $true
        }
    }
}

if (-not $ps2exeLoaded -or -not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    throw 'Could not load Invoke-ps2exe from ps2exe module.'
}
Write-Host '      ps2exe is ready.' -ForegroundColor Green

# 3. Generate App Icon in Temp
Write-Host '[2/5] Preparing application icon...' -ForegroundColor Yellow
Add-Type -AssemblyName System.Drawing
$tempIcon = Join-Path $env:TEMP 'fti_inventory.ico'
$bmp = New-Object System.Drawing.Bitmap(128, 128)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# Background rounded rect (Win11 Squircle)
$bgRect = New-Object System.Drawing.RectangleF(4, 4, 120, 120)
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(4, 4, 26, 26, 180, 90)
$path.AddArc(98, 4, 26, 26, 270, 90)
$path.AddArc(98, 98, 26, 26, 0, 90)
$path.AddArc(4, 98, 26, 26, 90, 90)
$path.CloseFigure()

$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $bgRect,
    [System.Drawing.Color]::FromArgb(255, 0, 103, 192),
    [System.Drawing.Color]::FromArgb(255, 15, 23, 42),
    [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
)
$g.FillPath($brush, $path)

# Monitor
$penWhite = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
$penWhite.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$penWhite.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$screenFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 245, 255))
$g.FillRectangle($screenFill, 22, 20, 84, 56)
$g.DrawRectangle($penWhite, 22, 20, 84, 56)
$g.DrawLine($penWhite, 64, 76, 64, 92)
$g.DrawLine($penWhite, 48, 92, 80, 92)

# Bars
$b1 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 103, 192))
$b2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 148, 163, 184))
$g.FillRectangle($b1, 30, 30, 40, 5)
$g.FillRectangle($b2, 30, 40, 60, 4)
$g.FillRectangle($b2, 30, 48, 50, 4)
$g.FillRectangle($b2, 30, 56, 68, 4)

# Badge
$badgeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 16, 185, 129))
$g.FillEllipse($badgeBrush, 72, 68, 44, 44)
$g.DrawEllipse($penWhite, 72, 68, 44, 44)

# Checkmark
$chkPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 4)
$chkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$chkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$p1 = New-Object System.Drawing.PointF(82, 90)
$p2 = New-Object System.Drawing.PointF(90, 98)
$p3 = New-Object System.Drawing.PointF(104, 80)
$g.DrawLines($chkPen, @($p1, $p2, $p3))
$g.Dispose()

$hIcon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)
$ms = New-Object System.IO.MemoryStream
$icon.Save($ms)
[System.IO.File]::WriteAllBytes($tempIcon, $ms.ToArray())
$ms.Dispose()
$icon.Dispose()
$bmp.Dispose()
Write-Host "      Icon generated at $tempIcon" -ForegroundColor Green

# 4. Merge Core.ps1 (Base64) + Web UI HTML (Base64) + AppServer.ps1
Write-Host '[3/5] Merging Core, Web UI, and Server into standalone script...' -ForegroundColor Yellow
$coreBytes   = [System.IO.File]::ReadAllBytes($srcCore)
$coreB64     = [System.Convert]::ToBase64String($coreBytes)
$htmlBytes   = [System.IO.File]::ReadAllBytes($srcHtml)
$htmlB64     = [System.Convert]::ToBase64String($htmlBytes)
$serverCode  = [System.IO.File]::ReadAllText($srcServer, [System.Text.Encoding]::UTF8)

$mergedContent = @"
# ==============================================================================
# FTI PC Inventory Tool (Compiled Executable - Modern Web App Engine)
# ==============================================================================
`$CoreScriptBase64 = '$coreB64'
`$CoreScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$CoreScriptBase64))

`$HtmlContentBase64 = '$htmlB64'
`$HtmlContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$HtmlContentBase64))

$serverCode
"@

$tempMerged = Join-Path $env:TEMP 'fti_inventory_merged.ps1'
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($tempMerged, $mergedContent, $utf8WithBom)
Write-Host "      Merged script prepared at $tempMerged" -ForegroundColor Green

# 5. Compile via PS2EXE
Write-Host '[4/5] Compiling to .EXE via PS2EXE...' -ForegroundColor Yellow
$targetExeInTemp = Join-Path $env:TEMP $ExeName
$finalTargetExe = Join-Path $OutputDir $ExeName

# Remove old exe in temp if present
try {
    if (Test-Path $targetExeInTemp) { Remove-Item $targetExeInTemp -Force -ErrorAction Stop }
} catch {
    Write-Warning "Existing $ExeName is currently running and locked. Compiling to a new temporary binary..."
    $ExeName = 'FTI_PC_Inventory_Updated.exe'
    $targetExeInTemp = Join-Path $env:TEMP $ExeName
    $finalTargetExe = Join-Path $OutputDir $ExeName
    if (Test-Path $targetExeInTemp) { Remove-Item $targetExeInTemp -Force -ErrorAction SilentlyContinue }
}

# Invoke ps2exe
Invoke-ps2exe `
    -inputFile $tempMerged `
    -outputFile $targetExeInTemp `
    -noConsole `
    -STA `
    -requireAdmin `
    -winFormsDPIAware `
    -iconFile $tempIcon `
    -title 'FTI PC Inventory Tool' `
    -description 'FTI PC Inventory Tool - Hardware and Software scanner' `
    -company 'FTI' `
    -product 'FTI PC Inventory' `
    -version '1.0.0.0' `
    -copyright 'FTI'

if (-not (Test-Path $targetExeInTemp)) {
    throw "PS2EXE compilation did not produce $targetExeInTemp"
}

Write-Host "      Compilation successful! Size: $((Get-Item $targetExeInTemp).Length) bytes" -ForegroundColor Green

# 6. Copy to dist or report location
Write-Host '[5/5] Deploying executable...' -ForegroundColor Yellow
$deployed = $false
try {
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    Copy-Item $targetExeInTemp $finalTargetExe -Force
    $deployed = $true
    Write-Host "      Output file: $finalTargetExe" -ForegroundColor Cyan
} catch {
    Write-Host "      Notice: Could not write directly to $OutputDir (Windows Controlled Folder Access)." -ForegroundColor Yellow
    Write-Host "      Executable is available at: $targetExeInTemp" -ForegroundColor Cyan
}

Write-Host ''
Write-Host '===================================================' -ForegroundColor Green
Write-Host '  BUILD COMPLETED SUCCESSFULLY!                     ' -ForegroundColor Green
Write-Host '===================================================' -ForegroundColor Green
if ($deployed) {
    Write-Host "Executable location: $finalTargetExe" -ForegroundColor White
} else {
    Write-Host "Executable location: $targetExeInTemp" -ForegroundColor White
    Write-Host "Tip: To copy to $OutputDir, run PowerShell as Administrator or add an exclusion." -ForegroundColor Gray
}
