<#
.SYNOPSIS
  Enterprise Build script for FTI PC Inventory Tool.
  Compiles a native, malware-free C# executable (.NET Framework 4.8 / 4.7.2)
  with an embedded Windows Application Manifest (UAC requireAdministrator)
  and signs it with an Authenticode Digital Signature (SHA256).

.USAGE
  powershell -ExecutionPolicy Bypass -File .\build.ps1
  powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipSign
#>

[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ExeName = 'FTI_PC_Inventory.exe',
    [string]$Version,
    [switch]$SkipSign = $false
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

# --- Resolve and Manage Build Version (Date-based: yyyy.MM.dd.<BuildCycle>) ---
Write-Host '      Resolving build version...' -ForegroundColor Gray
$versionFile = Join-Path $PSScriptRoot 'version.json'
$todayStr = (Get-Date).ToString('yyyy.MM.dd')
$nowTimestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$verData = $null
if (Test-Path $versionFile) {
    try {
        $verData = Get-Content -Path $versionFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {}
}

if ($Version) {
    # Custom version specified by user parameter
    $appVersion = $Version.Trim().TrimStart('v')
    $buildRevision = 1
    if ($appVersion -match '\.(\d+)$') {
        $buildRevision = [int]$Matches[1]
    }
} else {
    $buildRevision = 1
    if ($verData -and $verData.lastBuildDate -eq $todayStr) {
        $buildRevision = [int]$verData.buildRevision + 1
    }
    $appVersion = "$todayStr.$buildRevision"
}

$displayVersion = "v$appVersion Enterprise"
$verObj = [pscustomobject]@{
    version        = $appVersion
    displayVersion = $displayVersion
    lastBuildDate  = $todayStr
    buildRevision  = $buildRevision
    buildTimestamp = $nowTimestamp
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$verJsonContent = $verObj | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($versionFile, $verJsonContent, $utf8NoBom)
Write-Host "      Build Version: $displayVersion ($nowTimestamp)" -ForegroundColor Green

# Update Web UI Title & Version Tag in src/web/index.html
$htmlContentRaw = [System.IO.File]::ReadAllText($srcHtml, [System.Text.Encoding]::UTF8)
$htmlContentRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $htmlContentRaw,
    '<title>.*?</title>',
    "<title>FTI PC Inventory Tool - v$appVersion</title>"
)
$htmlContentRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $htmlContentRaw,
    '<span class="version-tag[^"]*".*?</span>',
    "<span class=""version-tag has-tooltip"" data-tooltip=""Build: $nowTimestamp"" id=""appVersionTag"">$displayVersion</span>"
)
[System.IO.File]::WriteAllText($srcHtml, $htmlContentRaw, $utf8NoBom)

# Update Assembly Version Attributes in src/host/Program.cs
$csContentRaw = [System.IO.File]::ReadAllText($srcCs, [System.Text.Encoding]::UTF8)
$csContentRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $csContentRaw,
    '\[assembly:\s*AssemblyVersion\(".*?"\)\]',
    "[assembly: AssemblyVersion(""$appVersion"")]"
)
$csContentRaw = [System.Text.RegularExpressions.Regex]::Replace(
    $csContentRaw,
    '\[assembly:\s*AssemblyFileVersion\(".*?"\)\]',
    "[assembly: AssemblyFileVersion(""$appVersion"")]"
)
if ($csContentRaw -match '\[assembly:\s*AssemblyInformationalVersion\(".*?"\)\]') {
    $csContentRaw = [System.Text.RegularExpressions.Regex]::Replace(
        $csContentRaw,
        '\[assembly:\s*AssemblyInformationalVersion\(".*?"\)\]',
        "[assembly: AssemblyInformationalVersion(""$displayVersion ($nowTimestamp)"")]"
    )
} else {
    $csContentRaw = $csContentRaw -replace '(\[assembly:\s*AssemblyFileVersion\(.*?\);?\])', "`$1`r`n[assembly: AssemblyInformationalVersion(`"$displayVersion ($nowTimestamp)`")]"
}
[System.IO.File]::WriteAllText($srcCs, $csContentRaw, $utf8NoBom)


# 2. Locate C# Compiler (csc.exe)
Write-Host '[1/7] Locating .NET C# Compiler (csc.exe)...' -ForegroundColor Yellow
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

# 3. Validate Web UI & JavaScript Syntax Integrity
Write-Host '[2/7] Validating Web UI & JavaScript syntax integrity...' -ForegroundColor Yellow
$browserPaths = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
)
$headlessBrowser = $browserPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($headlessBrowser) {
    $tempDump = Join-Path $tempDir 'syntax_test_dom.txt'
    $htmlUri = "file:///$($srcHtml.Replace('\', '/'))"
    & cmd.exe /c "`"$headlessBrowser`" --headless --disable-gpu --dump-dom `"$htmlUri`" 2>nul" | Out-File -FilePath $tempDump -Encoding utf8

    if (Test-Path $tempDump) {
        $domContent = Get-Content -Path $tempDump -Raw
        Remove-Item $tempDump -Force -ErrorAction SilentlyContinue

        $hasFatalBanner = $domContent.Contains('<div id="fatalJsBanner"')
        $hasJsLoaded = $domContent.Contains('data-js-loaded="true"')

        if ($hasFatalBanner -or -not $hasJsLoaded) {
            $errMsg = "JavaScript execution or syntax error detected in $srcHtml."
            if ($domContent -match 'id="fatalJsBanner"[^>]*><span>(.*?)</span>') {
                $errMsg += " Details: $($matches[1])"
            }
            Write-Host "      [ERROR] $errMsg" -ForegroundColor Red
            throw $errMsg
        }
        Write-Host "      Web UI syntax integrity verified (Zero syntax errors, full execution confirmed)." -ForegroundColor Green
    } else {
        Write-Warning "      Could not capture headless browser DOM dump; skipping automated UI validation."
    }
} else {
    Write-Warning "      No supported Chromium browser found for headless verification; skipping."
}

# 4. Generate App Icon in Temp
Write-Host '[3/7] Preparing modern application icon...' -ForegroundColor Yellow
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

# 5. Merge Engine Scripts (Core + HTML + Server)
Write-Host '[4/7] Merging Core, Web UI, and Server into unified engine...' -ForegroundColor Yellow
$coreBytes   = [System.IO.File]::ReadAllBytes($srcCore)
$coreB64     = [System.Convert]::ToBase64String($coreBytes)
$htmlBytes   = [System.IO.File]::ReadAllBytes($srcHtml)
$htmlB64     = [System.Convert]::ToBase64String($htmlBytes)
$serverCode  = [System.IO.File]::ReadAllText($srcServer, [System.Text.Encoding]::UTF8)

# Extract param block from $serverCode to ensure it is the very first statement
$paramBlock = "param([switch]`$Silent, [switch]`$ScheduledRun, [string]`$OutDir = 'C:\Inventory')"
$restOfServer = $serverCode
if ($serverCode -match '(?ms)^\s*param\s*\((.*?)\)\s*(.*)$') {
    $paramBlock = "param($($matches[1]))"
    $restOfServer = $matches[2]
}

$mergedContent = @"
$paramBlock
# ==============================================================================
# FTI PC Inventory Tool (Enterprise Standalone Web App Engine)
# ==============================================================================
`$AppVersion = '$displayVersion'
`$BuildTimestamp = '$nowTimestamp'
`$CoreScriptBase64 = '$coreB64'
`$CoreScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$CoreScriptBase64)).TrimStart([char]0xFEFF)

`$HtmlContentBase64 = '$htmlB64'
`$HtmlContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$HtmlContentBase64))

$restOfServer
"@

$mergedBytes = [System.Text.Encoding]::UTF8.GetBytes($mergedContent)

$tempMerged = Join-Path $tempDir 'engine_merged.ps1'
[System.IO.File]::WriteAllBytes($tempMerged, $mergedBytes)
Write-Host "      Engine script merged ($($mergedBytes.Length) bytes)" -ForegroundColor Green

# 6. Compile Native C# WinExe Launcher with Embedded Resource
Write-Host '[5/7] Compiling Native C# WinExe Launcher with Embedded Engine & Manifest...' -ForegroundColor Yellow

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
    "/resource:$tempMerged,FTI.Engine",
    "/out:$targetExeInTemp",
    $srcCs
)

& $cscPath $compileArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $targetExeInTemp)) {
    throw "C# compilation failed with exit code $LASTEXITCODE."
}
Write-Host "      Native .EXE created successfully! Size: $((Get-Item $targetExeInTemp).Length) bytes" -ForegroundColor Green

# 7. Authenticode Digital Signing
Write-Host '[6/7] Applying Authenticode Digital Signature (SHA256)...' -ForegroundColor Yellow
$cert = $null
if (-not $SkipSign) {
    try {
        $certSubject = "CN=Function International (FTI)"
        $cert = Get-ChildItem -Path Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $certSubject } | Select-Object -First 1

        if (-not $cert) {
            Write-Host "      Generating self-signed Enterprise Code Signing Certificate..." -ForegroundColor Gray
            $cert = New-SelfSignedCertificate `
                -Type CodeSigningCert `
                -Subject $certSubject `
                -CertStoreLocation "Cert:\CurrentUser\My" `
                -HashAlgorithm SHA256 `
                -NotAfter (Get-Date).AddYears(5) `
                -ErrorAction Stop
        }

        # Sign executable
        Set-AuthenticodeSignature -FilePath $targetExeInTemp -Certificate $cert -HashAlgorithm SHA256 | Out-Null
        $sig = Get-AuthenticodeSignature -FilePath $targetExeInTemp
        Write-Host "      Signature Status: $($sig.Status) (Signer: $($cert.Subject))" -ForegroundColor Green
    } catch {
        Write-Warning "Authenticode signing skipped: $($_.Exception.Message)"
        Write-Host "      [TIP] For signed release binaries, run PowerShell as Administrator." -ForegroundColor Cyan
        $cert = $null
    }
} else {
    Write-Host "      Signing skipped (-SkipSign specified)." -ForegroundColor Gray
}

# 8. Package and Deploy
Write-Host '[7/7] Packaging and Deploying...' -ForegroundColor Yellow

# Primary distribution folder ($OutputDir = $PSScriptRoot\dist)
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$finalTargetExe = Join-Path $OutputDir 'FTI_PC_Inventory.exe'
Copy-Item $targetExeInTemp $finalTargetExe -Force
Write-Host "      Successfully deployed to: $OutputDir" -ForegroundColor Cyan

$certExportPath = Join-Path $OutputDir 'FTI_Enterprise_Certificate.cer'
if ($cert) {
    try {
        Export-Certificate -Cert $cert -FilePath $certExportPath -Force | Out-Null
    } catch {
        Write-Warning "Could not export certificate: $($_.Exception.Message)"
    }
}

$installBatPath = Join-Path $OutputDir 'Install_Certificate.bat'
$installBat = @"
@echo off
title Install FTI Enterprise Security Certificate
echo ========================================================
echo   Function International (FTI) - Certificate Installer
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

# Secondary optional deployment: AppData
try {
    $appDistDir = Join-Path $env:LOCALAPPDATA 'FTI_PC_Inventory_Tool\dist'
    if (-not (Test-Path $appDistDir -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $appDistDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path $appDistDir -ErrorAction SilentlyContinue) {
        Copy-Item $finalTargetExe (Join-Path $appDistDir 'FTI_PC_Inventory.exe') -Force -ErrorAction SilentlyContinue
        if (Test-Path $certExportPath) {
            Copy-Item $certExportPath (Join-Path $appDistDir 'FTI_Enterprise_Certificate.cer') -Force -ErrorAction SilentlyContinue
        }
        Copy-Item $installBatPath (Join-Path $appDistDir 'Install_Certificate.bat') -Force -ErrorAction SilentlyContinue
    }
} catch {}

# Secondary optional deployment: Drive Root
try {
    $driveRoot = (Split-Path $PSScriptRoot -Qualifier) + '\'
    $rootExe = Join-Path $driveRoot 'FTI_PC_Inventory.exe'
    Copy-Item $finalTargetExe $rootExe -Force -ErrorAction SilentlyContinue
    if (Test-Path $rootExe) {
        Write-Host "      Drive Root Copy: $rootExe" -ForegroundColor Cyan
    }
} catch {}

Write-Host ''
Write-Host '===================================================' -ForegroundColor Green
Write-Host "  ENTERPRISE BUILD COMPLETED: $displayVersion" -ForegroundColor Green
Write-Host '===================================================' -ForegroundColor Green
Write-Host "1. Primary Executable: $finalTargetExe (v$appVersion)" -ForegroundColor White
if (Test-Path $certExportPath) {
    Write-Host "2. Public Certificate: $certExportPath" -ForegroundColor White
}
Write-Host "3. Install Batch:      $installBatPath" -ForegroundColor White
Write-Host '===================================================' -ForegroundColor Green
