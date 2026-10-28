<#
.SYNOPSIS
  Verify the development environment and prerequisites for FTI PC Inventory Tool.
#>
[CmdletBinding()]
param()

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  FTI PC Inventory Tool - Environment Diagnostics         " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

$allPass = $true

function Write-CheckItem {
    param([string]$Title, [bool]$Pass, [string]$Details = "")
    if ($Pass) {
        Write-Host "  [OK]   $Title" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Title" -ForegroundColor Red
        $script:allPass = $false
    }
    if ($Details) {
        Write-Host "         $Details" -ForegroundColor Gray
    }
}

# 1. PowerShell Version
$psVer = $PSVersionTable.PSVersion
Write-CheckItem -Title "PowerShell Runtime: $psVer" -Pass ($psVer.Major -ge 5) -Details "Requires PS 5.1 or later"

# 2. Execution Policy
$execPolicy = Get-ExecutionPolicy
Write-CheckItem -Title "PowerShell ExecutionPolicy: $execPolicy" -Pass ($execPolicy -ne 'Restricted') -Details "Run with -ExecutionPolicy Bypass if restricted"

# 3. .NET C# Native Compiler (csc.exe)
$cscPaths = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
)
$cscFound = $cscPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
Write-CheckItem -Title "C# Native Compiler (csc.exe)" -Pass ([bool]$cscFound) -Details "Found at: $cscFound"

# 4. Source Files Integrity
$projectRoot = Split-Path $PSScriptRoot -Parent
$sources = @(
    'src\Get-PCInventory.Core.ps1',
    'src\AppServer.ps1',
    'src\web\index.html',
    'src\host\Program.cs',
    'src\host\app.manifest',
    'build.ps1'
)
$missingSources = @()
foreach ($src in $sources) {
    $fullPath = Join-Path $projectRoot $src
    if (-not (Test-Path $fullPath)) { $missingSources += $src }
}
Write-CheckItem -Title "Source Files Integrity" -Pass ($missingSources.Count -eq 0) -Details $(if ($missingSources) { "Missing: $($missingSources -join ', ')" } else { "All $(($sources).Count) core source files present" })

# 5. PSScriptAnalyzer Module
$localModule = Join-Path $PSScriptRoot 'modules\PSScriptAnalyzer\1.25.0\PSScriptAnalyzer.psd1'
$linterAvailable = (Test-Path $localModule) -or (Get-Module -ListAvailable -Name PSScriptAnalyzer)
Write-CheckItem -Title "PSScriptAnalyzer Linter" -Pass ([bool]$linterAvailable) -Details "Available for static code analysis"

# 6. Git Tooling
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
Write-CheckItem -Title "Git Version Control" -Pass ([bool]$gitCmd) -Details $(if ($gitCmd) { "Git path: $($gitCmd.Source)" } else { "Git not detected in PATH" })

# 7. Administrator Privilege Check (For Digital Signing & Task Scheduler)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "  [INFO] Running with Administrator Privileges (Full Code Signing enabled)" -ForegroundColor Cyan
} else {
    Write-Host "  [INFO] Running as Standard User (Use 'Run as Administrator' for Authenticode signing)" -ForegroundColor Yellow
}

# 8. Dist Executable Build Status
$distExe = Join-Path $projectRoot 'dist\FTI_PC_Inventory.exe'
$isBuilt = Test-Path $distExe
if ($isBuilt) {
    $exeSize = (Get-Item $distExe).Length
    Write-CheckItem -Title "Compiled Binary (dist\FTI_PC_Inventory.exe)" -Pass $true -Details "Size: $exeSize bytes"
} else {
    Write-Host "  [NOTICE] Executable not yet compiled in dist\. Run build.ps1 to generate." -ForegroundColor Yellow
}

Write-Host "----------------------------------------------------------" -ForegroundColor Gray
if ($allPass) {
    Write-Host "Environment is 100% READY for development and building!" -ForegroundColor Green
} else {
    Write-Host "Some environment checks failed. Please review the items above." -ForegroundColor Red
}
Write-Host "==========================================================" -ForegroundColor Cyan

