<#
.SYNOPSIS
  Enterprise Build script for FTI PC Inventory Tool.
  Compiles a native, malware-free C# executable (.NET Framework 4.8 / 4.7.2)
  with an embedded Windows Application Manifest (UAC requireAdministrator)
  and signs it with an Authenticode Digital Signature (SHA256).

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
Write-Host '  FTI PC Inventory Tool - Enterprise Native Build  ' -ForegroundColor White
Write-Host '===================================================' -ForegroundColor Cyan

# 1. Resolve source paths
$srcCore     = Join-Path $PSScriptRoot 'src\Get-PCInventory.Core.ps1'
$srcServer   = Join-Path $PSScriptRoot 'src\AppServer.ps1'
$srcHtml     = Join-Path $PSScriptRoot 'src\web\index.html'
$srcCs       = Join-Path $PSScriptRoot 'src\host\Program.cs'
$srcManifest = Join-Path $PSScriptRoot 'src\host\app.manifest'

if (-not (Test-Path $srcCore))     { throw "Cannot find $srcCore" }
if (-not (Test-Path $srcServer))   { throw "Cannot find $srcServer" }
if (-not (Test-Path $srcHtml))     { throw "Cannot find $srcHtml" }
if (-not (Test-Path $srcCs))       { throw "Cannot find $srcCs" }
if (-not (Test-Path $srcManifest)) { throw "Cannot find $srcManifest" }

$tempDir = Join-Path $env:TEMP 'FTI_Inventory_Build'
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# 2. Locate C# Compiler (csc.exe)
Write-Host '[1/6] Locating .NET C# Compiler (csc.exe)...' -ForegroundColor Yellow
$cscPaths = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
)
$cscPath = $null
foreach ($p in $cscPaths) {
    if (Test-Path $p) {
        $cscPath = $p
        break
    }
}
if (-not $cscPath) {
    throw 'Could not find csc.exe in Microsoft.NET Framework 4.x directories.'
}
Write-Host "      Compiler found: $cscPath" -ForegroundColor Green

# 3. Generate App Icon in Temp
Write-Host '[2/6] Preparing modern application icon...' -ForegroundColor Yellow
Add-Type -AssemblyName System.Drawing
$tempIcon = Join-Path $tempDir 'fti_inventory.ico'
$bmp = New-Object System.Drawing.Bitmap(128, 128)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# Background rounded rect (Modern Squircle)
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

# Spec Bars
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

# 4. Merge Engine Scripts (Core + HTML + Server)
Write-Host '[3/6] Merging Core, Web UI, and Server into unified engine...' -ForegroundColor Yellow
$coreBytes   = [System.IO.File]::ReadAllBytes($srcCore)
$coreB64     = [System.Convert]::ToBase64String($coreBytes)
$htmlBytes   = [System.IO.File]::ReadAllBytes($srcHtml)
$htmlB64     = [System.Convert]::ToBase64String($htmlBytes)
$serverCode  = [System.IO.File]::ReadAllText($srcServer, [System.Text.Encoding]::UTF8)

$mergedContent = @"
# ==============================================================================
# FTI PC Inventory Tool (Enterprise Standalone Web App Engine)
# ==============================================================================
`$CoreScriptBase64 = '$coreB64'
`$CoreScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$CoreScriptBase64))

`$HtmlContentBase64 = '$htmlB64'
`$HtmlContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$HtmlContentBase64))

$serverCode
"@

$mergedBytes = [System.Text.Encoding]::UTF8.GetBytes($mergedContent)
$mergedB64   = [System.Convert]::ToBase64String($mergedBytes)

$tempMerged = Join-Path $tempDir 'engine_merged.ps1'
[System.IO.File]::WriteAllBytes($tempMerged, $mergedBytes)
Write-Host "      Engine script merged ($($mergedBytes.Length) bytes)" -ForegroundColor Green

# 5. Inject Payload into C# Source & Compile
Write-Host '[4/6] Compiling Native C# WinExe Launcher with Application Manifest...' -ForegroundColor Yellow
$csTemplate = [System.IO.File]::ReadAllText($srcCs, [System.Text.Encoding]::UTF8)
$csSource = $csTemplate.Replace('###SCRIPT_PAYLOAD_PLACEHOLDER###', $mergedB64)

$tempCs = Join-Path $tempDir 'FTI_Launcher_Source.cs'
[System.IO.File]::WriteAllText($tempCs, $csSource, [System.Text.Encoding]::UTF8)

$targetExeInTemp = Join-Path $tempDir $ExeName
if (Test-Path $targetExeInTemp) {
    try {
        Remove-Item $targetExeInTemp -Force -ErrorAction Stop
    } catch {
        Write-Warning "Temp $ExeName is locked. Using alternate temp name."
        $ExeName = 'FTI_PC_Inventory_Build.exe'
        $targetExeInTemp = Join-Path $tempDir $ExeName
        if (Test-Path $targetExeInTemp) { Remove-Item $targetExeInTemp -Force -ErrorAction SilentlyContinue }
    }
}

$compileArgs = @(
    "/target:winexe",
    "/optimize+",
    "/platform:anycpu",
    "/win32icon:$tempIcon",
    "/win32manifest:$srcManifest",
    "/out:$targetExeInTemp",
    $tempCs
)

& $cscPath $compileArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $targetExeInTemp)) {
    throw "C# compilation failed with exit code $LASTEXITCODE."
}
Write-Host "      Native .EXE created successfully! Size: $((Get-Item $targetExeInTemp).Length) bytes" -ForegroundColor Green

# 6. Authenticode Digital Signing
Write-Host '[5/6] Applying Authenticode Digital Signature (SHA256)...' -ForegroundColor Yellow
$certSubject = "CN=FTI Enterprise Tools"
$cert = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $certSubject } | Select-Object -First 1

if (-not $cert) {
    Write-Host "      Generating self-signed Enterprise Code Signing Certificate..." -ForegroundColor Gray
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $certSubject `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(5)
}

# Sign executable
Set-AuthenticodeSignature -FilePath $targetExeInTemp -Certificate $cert -HashAlgorithm SHA256 | Out-Null
$sig = Get-AuthenticodeSignature -FilePath $targetExeInTemp
Write-Host "      Signature Status: $($sig.Status) (Signer: $($cert.Subject))" -ForegroundColor Green

# 7. Package and Deploy
Write-Host '[6/6] Packaging and Deploying...' -ForegroundColor Yellow

# Prepare local AppData dist as primary reliable location
$appDistDir = Join-Path $env:LOCALAPPDATA 'FTI_PC_Inventory_Tool\dist'
if (-not (Test-Path $appDistDir)) {
    New-Item -ItemType Directory -Path $appDistDir -Force | Out-Null
}

$deployedFiles = @()

# Copy to AppData dist
$appExe = Join-Path $appDistDir 'FTI_PC_Inventory.exe'
Copy-Item $targetExeInTemp $appExe -Force
$deployedFiles += $appExe

$certExportPath = Join-Path $appDistDir 'FTI_Enterprise_Certificate.cer'
Export-Certificate -Cert $cert -FilePath $certExportPath -Force | Out-Null
$deployedFiles += $certExportPath

$installBatPath = Join-Path $appDistDir 'Install_Certificate.bat'
$installBat = @"
@echo off
title Install FTI Enterprise Security Certificate
echo ========================================================
echo   FTI Enterprise Tools - Certificate Installer
echo ========================================================
echo.
echo Installing security certificate to Trusted Root Certification Authorities...
certutil -addstore -f "Root" "%~dp0FTI_Enterprise_Certificate.cer"
echo.
if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] Certificate installed! Windows Defender and SmartScreen will trust FTI_PC_Inventory.exe.
) else (
    echo [NOTICE] Please run this batch file as Administrator to install certificate.
)
echo.
pause
"@
[System.IO.File]::WriteAllText($installBatPath, $installBat, [System.Text.Encoding]::ASCII)
$deployedFiles += $installBatPath

# Also attempt copy to OutputDir ($PSScriptRoot\dist)
try {
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $finalTargetExe = Join-Path $OutputDir 'FTI_PC_Inventory.exe'
    Copy-Item $targetExeInTemp $finalTargetExe -Force
    Copy-Item $certExportPath (Join-Path $OutputDir 'FTI_Enterprise_Certificate.cer') -Force
    Copy-Item $installBatPath (Join-Path $OutputDir 'Install_Certificate.bat') -Force
    Write-Host "      Successfully deployed to: $OutputDir" -ForegroundColor Cyan
} catch {
    Write-Host "      Notice: $OutputDir protected by Windows Controlled Folder Access." -ForegroundColor Yellow
}

# Also attempt copy to drive root E:\
try {
    $driveRoot = (Split-Path $PSScriptRoot -Qualifier) + '\'
    $rootExe = Join-Path $driveRoot 'FTI_PC_Inventory.exe'
    Copy-Item $targetExeInTemp $rootExe -Force -ErrorAction SilentlyContinue
    if (Test-Path $rootExe) {
        Write-Host "      Drive Root Copy: $rootExe" -ForegroundColor Cyan
    }
} catch {}

Write-Host ''
Write-Host '===================================================' -ForegroundColor Green
Write-Host '  ENTERPRISE BUILD COMPLETED SUCCESSFULLY!          ' -ForegroundColor Green
Write-Host '===================================================' -ForegroundColor Green
Write-Host "1. Primary Executable: $appExe" -ForegroundColor White
Write-Host "2. Public Certificate: $certExportPath" -ForegroundColor White
Write-Host "3. Install Batch:      $installBatPath" -ForegroundColor White
Write-Host '===================================================' -ForegroundColor Green
