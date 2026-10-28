<#
.SYNOPSIS
  Run PSScriptAnalyzer code linting on FTI PC Inventory Tool codebase.
#>
[CmdletBinding()]
param(
    [string]$Path
)

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if (-not $Path) {
    $Path = Join-Path $PSScriptRoot '..\src'
}

$localModule = Join-Path $PSScriptRoot 'modules\PSScriptAnalyzer\1.25.0\PSScriptAnalyzer.psd1'
if (Test-Path $localModule) {
    Import-Module $localModule -ErrorAction SilentlyContinue
} else {
    Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
}

if (-not (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
    Write-Error "PSScriptAnalyzer is not installed or available."
    exit 1
}

$settingsPath = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'
Write-Host "Analyzing PowerShell code in $Path..." -ForegroundColor Cyan

$results = Invoke-ScriptAnalyzer -Path $Path -Settings $settingsPath -Recurse

if ($results) {
    $results | Format-Table -Property Severity, ScriptName, Line, Message -AutoSize
    $errorCount = ($results | Where-Object { $_.Severity -eq 'Error' }).Count
    $warnCount = ($results | Where-Object { $_.Severity -eq 'Warning' }).Count
    Write-Host "Lint complete: $errorCount Errors, $warnCount Warnings found." -ForegroundColor Yellow
} else {
    Write-Host "All PowerShell scripts passed code quality checks! 0 Errors, 0 Warnings." -ForegroundColor Green
}

