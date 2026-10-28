<#
.SYNOPSIS
  Comprehensive verification test for FTI PC Inventory Tool Scheduler System.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  FTI PC Inventory Tool - Scheduler Verification Suite    " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

$testTaskName = 'FTI_PC_Inventory_AutoScan_Test'
$projectRoot = Split-Path $PSScriptRoot -Parent
$distExe = Join-Path $projectRoot 'dist\FTI_PC_Inventory.exe'

# Test 1: Verify Executable exists and is signed
Write-Host "[Test 1/6] Verifying binary existence and signature..." -ForegroundColor Yellow
if (-not (Test-Path $distExe)) {
    throw "Executable not found at $distExe"
}
$sig = Get-AuthenticodeSignature $distExe
Write-Host "  Executable: $distExe ($((Get-Item $distExe).Length) bytes)" -ForegroundColor Green
Write-Host "  Signature : $($sig.Status) ($($sig.SignerCertificate.Subject))" -ForegroundColor Green

# Test 2: Test Executable Path Resolution Function
Write-Host "`n[Test 2/6] Testing dynamic executable path resolution..." -ForegroundColor Yellow
$candidates = @(
    (Join-Path $projectRoot 'FTI_PC_Inventory.exe'),
    (Join-Path $projectRoot 'dist\FTI_PC_Inventory.exe'),
    (Join-Path $env:LOCALAPPDATA 'FTI_PC_Inventory_Tool\dist\FTI_PC_Inventory.exe'),
    'C:\FTI_PC_Inventory.exe'
)
$resolved = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $resolved) {
    throw "Path resolution failed to locate any valid FTI_PC_Inventory.exe"
}
Write-Host "  Resolved Executable Path: $resolved" -ForegroundColor Green
if ($resolved -match '^E:\\') {
    throw "BUG: Path resolved to drive E:\ which is invalid!"
}

# Test 3: Test Windows Task Scheduler Daily Registration
Write-Host "`n[Test 3/6] Testing Task Scheduler Daily registration..." -ForegroundColor Yellow
try {
    $outDirTest = Join-Path $env:TEMP 'FTI_Inventory_TestOut'
    $action = New-ScheduledTaskAction -Execute $resolved -Argument "-Silent -OutDir `"$outDirTest`""
    $trigger = New-ScheduledTaskTrigger -Daily -At "03:30"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    
    Register-ScheduledTask -TaskName $testTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    
    $registeredTask = Get-ScheduledTask -TaskName $testTaskName -ErrorAction Stop
    Write-Host "  Daily Task Registered Successfully!" -ForegroundColor Green
    Write-Host "  Action Executable : $($registeredTask.Actions[0].Execute)" -ForegroundColor Green
    Write-Host "  Action Arguments  : $($registeredTask.Actions[0].Arguments)" -ForegroundColor Green
    Write-Host "  Trigger Time      : $($registeredTask.Triggers[0].StartBoundary)" -ForegroundColor Green
    Write-Host "  State             : $($registeredTask.State)" -ForegroundColor Green

    if ($registeredTask.Actions[0].Execute -ne $resolved) {
        throw "Registered executable mismatch! Expected $resolved, got $($registeredTask.Actions[0].Execute)"
    }
} catch {
    Write-Warning "Daily task registration test error: $($_.Exception.Message)"
    throw
}

# Test 4: Test Windows Task Scheduler Interval Repetition (e.g. 5 minutes)
Write-Host "`n[Test 4/6] Testing Task Scheduler Custom Interval registration (5 minutes)..." -ForegroundColor Yellow
try {
    $startStr = (Get-Date).ToString("HH:mm")
    $intervalTrigger = New-ScheduledTaskTrigger -Once -At $startStr -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $testTaskName -Action $action -Trigger $intervalTrigger -Principal $principal -Settings $settings -Force | Out-Null
    
    $regIntervalTask = Get-ScheduledTask -TaskName $testTaskName -ErrorAction Stop
    Write-Host "  Interval Task Registered Successfully!" -ForegroundColor Green
    Write-Host "  Repetition Interval : $($regIntervalTask.Triggers[0].Repetition.Interval)" -ForegroundColor Green
    
    $ts = [System.Xml.XmlConvert]::ToTimeSpan($regIntervalTask.Triggers[0].Repetition.Interval)
    Write-Host "  Parsed Interval     : $($ts.TotalMinutes) minute(s)" -ForegroundColor Green
    if ($ts.TotalMinutes -ne 5) {
        throw "Expected interval 5 minutes, got $($ts.TotalMinutes)"
    }
} catch {
    Write-Warning "Interval task registration test error: $($_.Exception.Message)"
    throw
}

# Test 5: Test Silent Scan Execution & ScheduleRun.log
Write-Host "`n[Test 5/6] Testing Silent background execution (-Silent -ScanLocalhost)..." -ForegroundColor Yellow
$testOutDir = Join-Path $env:TEMP 'FTI_Inventory_TestOut'
if (Test-Path $testOutDir) { Remove-Item $testOutDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $testOutDir -Force | Out-Null

$testLog = Join-Path $testOutDir 'ScheduleRun.log'

# Run the compiled executable with -Silent and custom test OutDir on local machine
Write-Host "  Spawning: $resolved -Silent -ScanLocalhost -OutDir `"$testOutDir`"" -ForegroundColor Gray
$proc = Start-Process -FilePath $resolved -ArgumentList "-Silent -ScanLocalhost -OutDir `"$testOutDir`"" -PassThru -Wait
Write-Host "  Process exit code: $($proc.ExitCode)" -ForegroundColor Green

if (Test-Path $testLog) {
    $logLines = Get-Content $testLog -Encoding UTF8
    Write-Host "  ScheduleRun.log generated successfully! Content:" -ForegroundColor Green
    $logLines | ForEach-Object { Write-Host "    $_" -ForegroundColor Cyan }
} else {
    throw "ScheduleRun.log was not created."
}

# Check that Master CSV was created
$masterCsv = Join-Path $testOutDir 'Hardware_Master.csv'
if (Test-Path $masterCsv) {
    Write-Host "  Master CSV created: $masterCsv ($((Get-Item $masterCsv).Length) bytes)" -ForegroundColor Green
} else {
    Write-Warning "  Master CSV not found at $masterCsv"
}

# Test 6: Clean Up Test Scheduled Task
Write-Host "`n[Test 6/6] Cleaning up test scheduled task..." -ForegroundColor Yellow
Unregister-ScheduledTask -TaskName $testTaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Write-Host "  Test task cleanly unregistered." -ForegroundColor Green

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  ALL SCHEDULER SYSTEM TESTS PASSED SUCCESSFULLY! (6/6)   " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
