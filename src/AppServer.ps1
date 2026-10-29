param(
    [switch]$Silent,
    [switch]$ScheduledRun,
    [string]$OutDir = 'C:\Inventory',
    [string]$ComputerListFile,
    [switch]$ScanLocalhost
)

# --- 1. Resolve Core Engine & Web UI Assets ---
if (-not $CoreScript) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
if ($CoreScript) { $CoreScript = $CoreScript.TrimStart([char]0xFEFF) } else { (Get-Location).Path }
    $corePath = Join-Path $scriptDir 'Get-PCInventory.Core.ps1'
    if (-not (Test-Path $corePath)) { $corePath = Join-Path $scriptDir 'src\Get-PCInventory.Core.ps1' }
    if (Test-Path $corePath) {
        $CoreScript = [System.IO.File]::ReadAllText($corePath, [System.Text.Encoding]::UTF8)
    } else {
        $CoreScript = ''
    }
}

# --- Silent Mode for Scheduled Tasks / CLI Background Run ---
if ($Silent -or $ScheduledRun) {
    $startTime = [System.DateTime]::Now
    Write-Host "[FTI Inventory] Scheduled background run started at $startTime"
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $logFile = Join-Path $OutDir 'ScheduleRun.log'
    $stampStart = $startTime.ToString('yyyy-MM-dd HH:mm:ss')
    "[$stampStart] Scheduled background scan started (OutDir=$OutDir)." | Out-File $logFile -Append -Encoding UTF8

    try {
        $coreParams = @{
            OutDir     = $OutDir
            MasterMode = $true
        }
        if ($ComputerListFile) { $coreParams['ComputerListFile'] = $ComputerListFile }
        if ($ScanLocalhost)    { $coreParams['ScanLocalhost']    = $true }
        $ps = [powershell]::Create()
        [void]$ps.AddScript($CoreScript)
        foreach ($k in $coreParams.Keys) {
            [void]$ps.AddParameter($k, $coreParams[$k])
        }
        $res = $ps.Invoke()
        if ($ps.Streams.Error.Count -gt 0) {
            $errMsgs = @($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "; "
            Write-Warning "Scan warnings/errors: $errMsgs"
        }
        $duration = [math]::Round(([System.DateTime]::Now - $startTime).TotalSeconds, 1)
        $stampEnd = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        "[$stampEnd] Scheduled scan finished in $($duration)s. Status=Success" | Out-File $logFile -Append -Encoding UTF8
    } catch {
        $stampErr = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        "[$stampErr] Scheduled scan failed: $($_.Exception.Message)" | Out-File $logFile -Append -Encoding UTF8
    }
    exit 0
}

Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not $HtmlContent) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $htmlPath = Join-Path $scriptDir 'web\index.html'
    if (-not (Test-Path $htmlPath)) { $htmlPath = Join-Path $scriptDir 'src\web\index.html' }
    if (Test-Path $htmlPath) {
        $HtmlContent = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
    } else {
        $HtmlContent = '<h1>Error: Web UI assets missing</h1>'
    }
}

# --- 2. Check Administrator Privilege ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- 3. Allocate Free Local Port ---
$listener = $null
$port = 52100
for ($p = 52100; $p -le 52500; $p++) {
    try {
        $testListener = New-Object System.Net.HttpListener
        $testListener.Prefixes.Add("http://127.0.0.1:$p/")
        $testListener.Start()
        $listener = $testListener
        $port = $p
        break
    } catch {
        if ($testListener) { try { $testListener.Close() } catch {} }
    }
}

if (-not $listener) {
    throw "Unable to bind HttpListener to any local port between 52100-52500."
}
Write-Host "APP_PORT=$port"
Write-SystemLog "INFO" "FTI Backend Engine started on http://127.0.0.1:$port (Admin=$isAdmin)"

# --- 4. Global State Tracking ---
$script:psInstance      = $null
$script:asyncResult     = $null
$script:scanStartTime   = $null
$script:scanEndTime     = $null
$script:isCompleted     = $false
$script:percent         = 0
$script:total           = 0
$script:ok              = 0
$script:offline         = 0
$script:errCount        = 0
$script:currentActivity = 'Ready'
$script:lastHtmlReport  = $null
$script:autoOpenHtml    = $true
$script:lastLogs        = [System.Collections.Generic.List[string]]::new()
$script:scannedPCs      = [System.Collections.Generic.List[hashtable]]::new()
$script:scanStep        = 0
$script:scanStepText    = 'Ready'
$script:systemLogs      = [System.Collections.Generic.List[string]]::new()
$script:sentSystemLogIndex = 0

function Write-SystemLog([string]$level, [string]$message) {
    $ts = [System.DateTime]::Now.ToString('HH:mm:ss')
    $entry = "[$ts][$level] $message"
    $script:systemLogs.Add($entry)
    if ($script:systemLogs.Count -gt 500) {
        $rem = $script:systemLogs.Count - 500
        $script:systemLogs.RemoveRange(0, $rem)
        if ($script:sentSystemLogIndex -ge $rem) {
            $script:sentSystemLogIndex -= $rem
        } else {
            $script:sentSystemLogIndex = 0
        }
    }
}

$script:lastInfoIndex   = 0
$script:lastWarnIndex   = 0
$script:lastErrIndex    = 0
$script:lastProgIndex   = 0
$script:sentLogIndex    = 0

# Scheduler State Tracking
$script:inAppSchedule = @{
    enabled         = $false
    intervalMinutes = 240
    nextRunAt       = $null
    lastRunAt       = $null
}
$script:lastScanParams = $null
$script:lastOutDir = 'C:\Inventory'

# Helper: Find the real FTI_PC_Inventory.exe
function Get-FtiExecutablePath() {
    if ($env:FTI_HOST_EXE -and (Test-Path -LiteralPath $env:FTI_HOST_EXE)) {
        return (Resolve-Path -LiteralPath $env:FTI_HOST_EXE).Path
    }
    $candidates = @(
        (Join-Path $PSScriptRoot 'FTI_PC_Inventory.exe'),
        (Join-Path $PSScriptRoot 'dist\FTI_PC_Inventory.exe'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\FTI_PC_Inventory.exe'),
        (Join-Path $env:LOCALAPPDATA 'FTI_PC_Inventory_Tool\dist\FTI_PC_Inventory.exe'),
        'C:\FTI_PC_Inventory.exe'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

# Helper: Read detailed Windows Task Scheduler info + last execution log
function Get-FtiWinTaskInfo() {
    $info = @{
        registered      = $false
        state           = 'NotRegistered'
        mode            = 'daily'
        time            = '02:00'
        intervalMinutes = 15
        lastRunTime     = $null
        lastTaskResult  = $null
        exePath         = $null
        logExcerpt      = $null
    }
    try {
        $t = Get-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -ErrorAction SilentlyContinue
        if ($t) {
            $info.registered = $true
            $info.state = $t.State.ToString()
            if ($t.Triggers -and $t.Triggers[0]) {
                if ($t.Triggers[0].Repetition -and $t.Triggers[0].Repetition.Interval) {
                    $info.mode = 'interval'
                    try {
                        $ts = [System.Xml.XmlConvert]::ToTimeSpan($t.Triggers[0].Repetition.Interval)
                        $info.intervalMinutes = [int]$ts.TotalMinutes
                    } catch {
                        $info.intervalMinutes = 15
                    }
                } else {
                    $info.mode = 'daily'
                    if ($t.Triggers[0].StartBoundary) {
                        try {
                            $info.time = ([datetime]$t.Triggers[0].StartBoundary).ToString('HH:mm')
                        } catch {}
                    }
                }
            }
            if ($t.Actions -and $t.Actions[0]) {
                $info.exePath = $t.Actions[0].Execute
            }
            try {
                $tInfo = Get-ScheduledTaskInfo -TaskName 'FTI_PC_Inventory_AutoScan' -ErrorAction SilentlyContinue
                if ($tInfo) {
                    if ($tInfo.LastRunTime -and $tInfo.LastRunTime -ne [datetime]::MinValue) {
                        $info.lastRunTime = $tInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                    $info.lastTaskResult = $tInfo.LastTaskResult
                }
            } catch {}
        }
    } catch {}

    # Read last 5 lines of ScheduleRun.log if available
    try {
        $logPath = Join-Path $script:lastOutDir 'ScheduleRun.log'
        if (-not (Test-Path -LiteralPath $logPath)) {
            $logPath = 'C:\Inventory\ScheduleRun.log'
        }
        if (Test-Path -LiteralPath $logPath) {
            $lines = Get-Content -LiteralPath $logPath -Tail 5 -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($lines) {
                $info.logExcerpt = @($lines)
            }
        }
    } catch {}

    return $info
}

# --- 5. Background Stream Pump Function ---
function Update-ScanProgress() {
    if (-not $script:psInstance) { return }

    $streams = $script:psInstance.Streams

    # 1. Information Stream
    if ($streams.Information.Count -gt $script:lastInfoIndex) {
        for ($i = $script:lastInfoIndex; $i -lt $streams.Information.Count; $i++) {
            $msg = $streams.Information[$i].MessageData.ToString()

            if ($msg -match '^\[STEP:(\d+)\]\s*(.*)$') {
                $script:scanStep = [int]$Matches[1]
                $script:scanStepText = $Matches[2]
                $script:lastLogs.Add($msg)
                Write-SystemLog 'STEP' ("Phase " + $script:scanStep + ": " + $script:scanStepText)
            }
            elseif ($msg -match '^\[LIVE_PC\]\s*(\{.*\})$') {
                try {
                    $live = $Matches[1] | ConvertFrom-Json
                    if ($live -and $live.PCName) {
                        $pcItem = @{
                            PCName       = [string]$live.PCName
                            Status       = [string]$live.Status
                            Fail_Count   = if ($live.Fail_Count) { [string]$live.Fail_Count } else { '0' }
                            Win_License  = if ($live.Win_License) { [string]$live.Win_License } else { '-' }
                            User         = if ($live.User) { [string]$live.User } else { '-' }
                            Maker        = if ($live.Maker) { [string]$live.Maker } else { '-' }
                            Model        = if ($live.Model) { [string]$live.Model } else { '-' }
                            Serial       = if ($live.Serial) { [string]$live.Serial } else { '-' }
                            CPU          = if ($live.CPU) { [string]$live.CPU } else { '-' }
                            Cores        = if ($live.Cores) { [string]$live.Cores } else { '-' }
                            RAM_GB       = if ($live.RAM_GB) { [string]$live.RAM_GB } else { '-' }
                            Disk_C_Free  = if ($live.Disk_C_Free) { [string]$live.Disk_C_Free } else { '-' }
                            Disks        = if ($live.Disks) { [string]$live.Disks } else { '-' }
                            GPU          = if ($live.GPU) { [string]$live.GPU } else { '-' }
                            OS           = if ($live.OS) { [string]$live.OS } else { '-' }
                            OSBuild      = if ($live.OSBuild) { [string]$live.OSBuild } else { '-' }
                            IP           = if ($live.IP) { [string]$live.IP } else { '-' }
                            Last_Boot    = if ($live.Last_Boot) { [string]$live.Last_Boot } else { '-' }
                            Uptime       = if ($live.Uptime) { [string]$live.Uptime } else { '-' }
                            AD_LastLogon = if ($live.AD_LastLogon) { [string]$live.AD_LastLogon } else { '-' }
                            AD_OU        = if ($live.AD_OU) { [string]$live.AD_OU } else { '-' }
                            Scan_Count   = if ($live.Scan_Count) { [string]$live.Scan_Count } else { '1' }
                            First_Seen   = if ($live.First_Seen) { [string]$live.First_Seen } else { '-' }
                            Last_Scan    = if ($live.Last_Scan) { [string]$live.Last_Scan } else { '-' }
                        }
                        $existingIdx = -1
                        for ($k = 0; $k -lt $script:scannedPCs.Count; $k++) {
                            if ($script:scannedPCs[$k].PCName -ieq $live.PCName) {
                                $existingIdx = $k
                                break
                            }
                        }
                        if ($existingIdx -ge 0) {
                            $script:scannedPCs[$existingIdx] = $pcItem
                        } else {
                            $script:scannedPCs.Add($pcItem)
                        }
                        # Recalculate real-time counters
                        $script:ok = @($script:scannedPCs | Where-Object { $_.Status -eq 'OK' }).Count
                        $script:offline = @($script:scannedPCs | Where-Object { $_.Status -match 'Offline' }).Count
                        $script:errCount = @($script:scannedPCs | Where-Object { $_.Status -match 'Error' }).Count
                        if ($script:scannedPCs.Count -gt $script:total) {
                            $script:total = $script:scannedPCs.Count
                        }
                        $specInfo = if ($live.Status -eq 'OK' -and $live.CPU -and $live.CPU -ne '-') { ' [' + $live.CPU + ' | ' + $live.RAM_GB + 'GB]' } else { '' }
                        $script:lastLogs.Add("[LIVE] " + $live.PCName + " -> " + $live.Status + $specInfo)
                    }
                } catch {
                    $script:lastLogs.Add($msg)
                }
            }
            else {
                $script:lastLogs.Add($msg)
                if ($msg -match 'Computers to scan:\s+(\d+)') {
                    $script:total = [int]$Matches[1]
                }
                elseif ($msg -match 'Software done\.\s+OK:\s+(\d+)') {
                    $script:ok = [int]$Matches[1]
                }
            }
        }
        $script:lastInfoIndex = $streams.Information.Count
    }

    # 2. Warning Stream
    if ($streams.Warning.Count -gt $script:lastWarnIndex) {
        for ($i = $script:lastWarnIndex; $i -lt $streams.Warning.Count; $i++) {
            $w = $streams.Warning[$i].Message
            $script:lastLogs.Add("[WARNING] $w")
            if ($w -match 'Offline|not reachable') {
                $script:offline++
            }
        }
        $script:lastWarnIndex = $streams.Warning.Count
    }

    # 3. Error Stream
    if ($streams.Error.Count -gt $script:lastErrIndex) {
        for ($i = $script:lastErrIndex; $i -lt $streams.Error.Count; $i++) {
            $err = $streams.Error[$i].ToString()
            $script:lastLogs.Add("[ERROR] $err")
            $script:errCount++
        }
        $script:lastErrIndex = $streams.Error.Count
    }

    # 4. Progress Stream
    if ($streams.Progress.Count -gt $script:lastProgIndex) {
        for ($i = $script:lastProgIndex; $i -lt $streams.Progress.Count; $i++) {
            $p = $streams.Progress[$i]
            if ($p.PercentComplete -ge 0 -and $p.PercentComplete -le 100) {
                $script:percent = $p.PercentComplete
            }
            $script:currentActivity = "$($p.Activity): $($p.StatusDescription)"

            # Parse machine scan record from status description
            if ($p.StatusDescription -match '^([^\s]+)\s+\((\d+)/(\d+)\)') {
                $pcName = $Matches[1]
                $existing = $script:scannedPCs | Where-Object { $_.PCName -eq $pcName }
                if (-not $existing) {
                    $script:scannedPCs.Add(@{
                        PCName       = $pcName
                        Status       = 'Scanning'
                        CPU          = '...'
                        RAM_GB       = ''
                        Disk_C_Free  = ''
                        OS           = '...'
                        OSBuild      = '...'
                        IP           = '...'
                        Last_Boot    = ''
                        Uptime       = ''
                        AD_LastLogon = ''
                        AD_OU        = ''
                        Scan_Count   = ''
                    })
                }
            }
        }
        $script:lastProgIndex = $streams.Progress.Count
    }

    # 5. Check Completion
    if ($script:asyncResult -and $script:asyncResult.IsCompleted) {
        $script:isCompleted = $true
        $script:percent = 100
        $script:scanStep = 5
        $script:scanStepText = 'Scan and Report Generation Completed'
        $script:currentActivity = 'Scan Completed'
        if (-not $script:scanEndTime) {
            $script:scanEndTime = [System.DateTime]::Now
        }

        try {
            $res = $script:psInstance.EndInvoke($script:asyncResult)
            if ($res -and $res.Count -gt 0) {
                $lastObj = $res[$res.Count - 1]
                if ($lastObj -and $lastObj.SoftwareHtml) {
                    $script:lastHtmlReport = $lastObj.SoftwareHtml
                }

                $csvToLoad = if ($lastObj -and $lastObj.MasterCsv -and (Test-Path -LiteralPath $lastObj.MasterCsv)) {
                    $lastObj.MasterCsv
                } elseif ($lastObj -and $lastObj.HardwareCsv -and (Test-Path -LiteralPath $lastObj.HardwareCsv)) {
                    $lastObj.HardwareCsv
                } else { $null }

                if ($csvToLoad) {
                    try {
                        $csvHw = Import-Csv -LiteralPath $csvToLoad -Encoding UTF8
                        if ($csvHw -and $csvHw.Count -gt 0) {
                            $script:scannedPCs.Clear()
                            foreach ($row in $csvHw) {
                                $script:scannedPCs.Add(@{
                                    PCName       = $row.PCName
                                    Status       = if ($row.Status) { $row.Status } else { 'OK' }
                                    Fail_Count   = if ($row.Fail_Count) { $row.Fail_Count } else { '0' }
                                    Win_License  = if ($row.Win_License) { $row.Win_License } else { '-' }
                                    User         = if ($row.User) { $row.User } else { '-' }
                                    Maker        = if ($row.Maker) { $row.Maker } else { '-' }
                                    Model        = if ($row.Model) { $row.Model } else { '-' }
                                    CPU          = if ($row.CPU) { $row.CPU } else { '-' }
                                    RAM_GB       = if ($row.RAM_GB) { $row.RAM_GB } else { '-' }
                                    Disk_C_Free  = if ($row.Disk_C_Free) { $row.Disk_C_Free } else { '-' }
                                    OS           = if ($row.OS) { $row.OS } else { '-' }
                                    OSBuild      = if ($row.OSBuild) { $row.OSBuild } else { '-' }
                                    IP           = if ($row.IP) { $row.IP } else { '-' }
                                    Last_Boot    = if ($row.Last_Boot) { $row.Last_Boot } else { '-' }
                                    Uptime       = if ($row.Uptime) { $row.Uptime } else { '-' }
                                    AD_LastLogon = if ($row.AD_LastLogon) { $row.AD_LastLogon } else { '-' }
                                    AD_OU        = if ($row.AD_OU) { $row.AD_OU } else { '-' }
                                    Scan_Count   = if ($row.Scan_Count) { $row.Scan_Count } else { '1' }
                                    First_Seen   = if ($row.First_Seen) { $row.First_Seen } else { '-' }
                                    Last_Scan    = if ($row.Last_Scan) { $row.Last_Scan } else { '-' }
                                })
                            }
                        }
                    } catch {}
                }
                if ($lastObj -and $lastObj.Status -eq 'Error') {
                    $script:lastLogs.Add("[ERROR] $($lastObj.Message)")
                    $script:errCount++
                }
            }
        } catch {
            $script:lastLogs.Add("[EXCEPTION] $($_.Exception.Message)")
        } finally {
            $script:psInstance.Dispose()
            $script:psInstance = $null
            $script:asyncResult = $null
        }

        # Ensure no machine stays with 'Scanning' status after scan completes
        foreach ($pc in $script:scannedPCs) {
            if ($pc.Status -eq 'Scanning') {
                $pc.Status = 'OK'
            }
        }
        $script:ok = @($script:scannedPCs | Where-Object { $_.Status -eq 'OK' }).Count
        $script:offline = @($script:scannedPCs | Where-Object { $_.Status -match 'Offline' }).Count
        $script:errCount = @($script:scannedPCs | Where-Object { $_.Status -match 'Error' }).Count
        $script:total = $script:scannedPCs.Count

        # Auto open HTML report if enabled
        if ($script:autoOpenHtml -and $script:lastHtmlReport -and (Test-Path $script:lastHtmlReport)) {
            try {
                [System.Diagnostics.Process]::Start($script:lastHtmlReport) | Out-Null
                $script:lastLogs.Add("Auto-opened report: $script:lastHtmlReport")
            } catch {}
        }
    }
}

# --- Core Scan Invoker Helper ---
function Start-ExecutionScan([hashtable]$params) {
    if ($script:psInstance) { return $false }

    $outDir = [string]$params.outDir
    if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = 'C:\Inventory' }
    $script:lastOutDir = $outDir

    if ($params.source -eq 'file') {
        $listFile = [string]$params.listFile
        if ([string]::IsNullOrWhiteSpace($listFile) -or -not (Test-Path -LiteralPath $listFile)) {
            throw "File not found: $listFile"
        }
    }

    if (-not (Test-Path -LiteralPath $outDir)) {
        [void](New-Item -ItemType Directory -Path $outDir -Force)
    }

    $script:isCompleted     = $false
    $script:percent         = 0
    $script:total           = 0
    $script:ok              = 0
    $script:offline         = 0
    $script:errCount        = 0
    $script:scanStep        = 1
    $script:scanStepText    = 'Target Discovery'
    $script:currentActivity = 'Preparing scan...'
    $script:lastHtmlReport  = $null
    $script:autoOpenHtml    = if ($params.ContainsKey('autoHtml')) { [bool]$params.autoHtml } else { $true }
    $script:lastLogs.Clear()
    $script:scannedPCs.Clear()
    $script:lastInfoIndex   = 0
    $script:lastWarnIndex   = 0
    $script:lastErrIndex    = 0
    $script:lastProgIndex   = 0
    $script:sentLogIndex    = 0
    $script:scanStartTime   = [System.DateTime]::Now
    $script:scanEndTime     = $null

    $script:psInstance = [powershell]::Create()
    [void]$script:psInstance.AddScript($CoreScript)

    $isHw = if ($params.ContainsKey('scanHw')) { [bool]$params.scanHw } else { $true }
    $isSw = if ($params.ContainsKey('scanSw')) { [bool]$params.scanSw } else { $true }
    [void]$script:psInstance.AddParameter('NoSoftware', (-not $isSw))
    [void]$script:psInstance.AddParameter('SkipHardware', (-not $isHw))
    [void]$script:psInstance.AddParameter('NameFilter', [string]$params.nameFilter)
    [void]$script:psInstance.AddParameter('IncludeUserInstalls', [bool]$params.includeUser)
    [void]$script:psInstance.AddParameter('IncludeHidden', [bool]$params.includeHidden)
    [void]$script:psInstance.AddParameter('DaysActive', [int]$params.daysActive)
    [void]$script:psInstance.AddParameter('Throttle', [int]$params.throttle)
    [void]$script:psInstance.AddParameter('OutDir', $outDir)

    $isMaster = if ($params.ContainsKey('masterMode')) { [bool]$params.masterMode } else { $true }
    $isRetryOffline = if ($params.ContainsKey('retryOfflineOnly')) { [bool]$params.retryOfflineOnly } else { $false }
    $isSkipServers = if ($params.ContainsKey('skipServers')) { [bool]$params.skipServers } else { $true }
    [void]$script:psInstance.AddParameter('MasterMode', $isMaster)
    [void]$script:psInstance.AddParameter('RetryOfflineOnly', $isRetryOffline)
    [void]$script:psInstance.AddParameter('SkipServers', $isSkipServers)
    if ($params.ContainsKey('excludeServerFile') -and [string]$params.excludeServerFile) {
        [void]$script:psInstance.AddParameter('ExcludeServerFile', [string]$params.excludeServerFile)
        Write-SystemLog 'INFO' ('Server exclusion file specified: ' + [string]$params.excludeServerFile)
    }

    if ($params.source -eq 'localhost') {
        [void]$script:psInstance.AddParameter('ScanLocalhost', $true)
    }
    elseif ($params.source -eq 'file' -and $params.listFile) {
        [void]$script:psInstance.AddParameter('ComputerListFile', [string]$params.listFile)
    }

    Write-SystemLog 'INFO' ('Execution scan started. Source=' + $params.source + ', OutDir=' + $outDir + ', MasterMode=' + $isMaster + ', SkipServers=' + $isSkipServers)
    $script:asyncResult = $script:psInstance.BeginInvoke()
    return $true
}

# --- 6. Launch Standalone Edge / Chrome App Window ---
$pf86 = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
$pf = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles)
$localApp = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)

$browserPaths = @(
    (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $pf 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $localApp 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $pf 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $pf86 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $localApp 'Google\Chrome\Application\chrome.exe')
)
$browserExe = $browserPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

$tempProfile = Join-Path $env:TEMP 'fti_inventory_web_profile'
if (-not (Test-Path $tempProfile)) {
    New-Item -ItemType Directory -Path $tempProfile -Force | Out-Null
} else {
    try {
        $lockFile = Join-Path $tempProfile 'SingletonLock'
        if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
    } catch {}
}

$appUrl = "http://127.0.0.1:$port/"
$appArgs = "--app=`"$appUrl`" --user-data-dir=`"$tempProfile`" --window-size=1260,860"

try {
    if ($browserExe) {
        Start-Process -FilePath $browserExe -ArgumentList $appArgs | Out-Null
    } else {
        Start-Process $appUrl | Out-Null
    }
} catch {
    Start-Process $appUrl | Out-Null
}

# --- 7. Main HTTP Request Loop with Hardened Heartbeat Lifecycle ---
$script:lastHeartbeat = [System.DateTime]::Now
$script:hasConnected = $false
$script:exitRequestedAt = $null
$running = $true
$pendingAsync = $null

while ($running) {
    # Pump scan streams
    Update-ScanProgress

    $scanRunning = ($null -ne $script:psInstance)

    # In-App recurring schedule trigger
    if ($script:inAppSchedule.enabled -and $script:inAppSchedule.nextRunAt) {
        if ([System.DateTime]::Now -ge $script:inAppSchedule.nextRunAt) {
            $intervalMins = if ($script:inAppSchedule.intervalMinutes -ge 1) { [int]$script:inAppSchedule.intervalMinutes } else { 240 }
            if ($scanRunning) {
                # Overlap prevention: Skip this trigger if already scanning
                $script:lastLogs.Add("[Scheduler] Previous scan still running at $(Get-Date -Format 'HH:mm:ss'). Skipping trigger.")
                $script:inAppSchedule.nextRunAt = [System.DateTime]::Now.AddMinutes($intervalMins)
            } else {
                $script:inAppSchedule.lastRunAt = [System.DateTime]::Now
                $script:inAppSchedule.nextRunAt = [System.DateTime]::Now.AddMinutes($intervalMins)
                $script:lastLogs.Add("[Scheduler] Auto-scan triggered at $(Get-Date -Format 'HH:mm:ss') (Interval: $intervalMins min)")
            
            $autoParams = if ($script:lastScanParams) { $script:lastScanParams } else {
                @{
                    source           = 'ad'
                    outDir           = $script:lastOutDir
                    scanHw           = $true
                    scanSw           = $true
                    masterMode       = $true
                    retryOfflineOnly = $false
                    daysActive       = 30
                    throttle         = 20
                }
            }
            try {
                Start-ExecutionScan $autoParams | Out-Null
            } catch {
                $script:lastLogs.Add("[Scheduler Error] $($_.Exception.Message)")
            }
        }
    }
    }

    # 1. Graceful exit scheduled by browser window close beacon (after 3s grace if no reload/request)
    if ($script:exitRequestedAt -and -not $scanRunning) {
        if (([System.DateTime]::Now - $script:exitRequestedAt).TotalSeconds -gt 3) {
            $running = $false
            break
        }
    }

    # 2. Heartbeat timeout (never exit while a scan is actively running!)
    if ($script:hasConnected) {
        if (-not $scanRunning -and (([System.DateTime]::Now - $script:lastHeartbeat).TotalSeconds -gt 60)) {
            $running = $false
            break
        }
    } else {
        # Allow 60 seconds for initial launch
        if (([System.DateTime]::Now - $script:lastHeartbeat).TotalSeconds -gt 60) {
            $running = $false
            break
        }
    }

    # Non-blocking async accept (reuse single pending async context)
    if ($null -eq $pendingAsync) {
        try {
            $pendingAsync = $listener.BeginGetContext($null, $null)
        } catch {
            break
        }
    }

    $waited = $pendingAsync.AsyncWaitHandle.WaitOne(150)

    if ($waited) {
        try {
            $context = $listener.EndGetContext($pendingAsync)
        } catch {
            $pendingAsync = $null
            continue
        }
        $pendingAsync = $null
        $req = $context.Request
        $res = $context.Response

        $script:lastHeartbeat = [System.DateTime]::Now
        $script:hasConnected = $true
        $script:exitRequestedAt = $null

        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        try {
            if ($path -eq '/' -or $path -eq '/index.html') {
                $buf = [System.Text.Encoding]::UTF8.GetBytes($HtmlContent)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/status' -and $method -eq 'GET') {
                Update-ScanProgress

                $elapsedStr = '00:00'
                if ($script:scanStartTime) {
                    $endTime = if ($script:scanEndTime) { $script:scanEndTime } else { [System.DateTime]::Now }
                    $ts = $endTime - $script:scanStartTime
                    $elapsedStr = $ts.ToString('mm\:ss')
                }

                $newLogs = @()
                if ($script:lastLogs.Count -gt $script:sentLogIndex) {
                    $newLogs = @($script:lastLogs.GetRange($script:sentLogIndex, ($script:lastLogs.Count - $script:sentLogIndex)))
                    $script:sentLogIndex = $script:lastLogs.Count
                }

                $newSystemLogs = @()
                if ($script:systemLogs.Count -gt $script:sentSystemLogIndex) {
                    $newSystemLogs = @($script:systemLogs.GetRange($script:sentSystemLogIndex, ($script:systemLogs.Count - $script:sentSystemLogIndex)))
                    $script:sentSystemLogIndex = $script:systemLogs.Count
                }

                # Calculate In-App schedule countdown
                $countdownSec = 0
                $nextRunStr = '-'
                if ($script:inAppSchedule.enabled -and $script:inAppSchedule.nextRunAt) {
                    $diff = $script:inAppSchedule.nextRunAt - [System.DateTime]::Now
                    if ($diff.TotalSeconds -gt 0) {
                        $countdownSec = [math]::Floor($diff.TotalSeconds)
                        $nextRunStr = $script:inAppSchedule.nextRunAt.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                }

                # Check Windows Task Scheduler
                $winTaskInfo = Get-FtiWinTaskInfo

                $offlineMachinesCount = @($script:scannedPCs | Where-Object { $_.Status -match 'Offline|Error' }).Count

                $statusObj = @{
                    isAdmin               = $isAdmin
                    isScanning            = ($null -ne $script:psInstance)
                    isCompleted           = $script:isCompleted
                    percent               = $script:percent
                    elapsed               = $elapsedStr
                    currentActivity       = $script:currentActivity
                    total                 = $script:total
                    ok                    = $script:ok
                    offline               = $script:offline
                    error                 = $script:errCount
                    offlineMachinesCount  = $offlineMachinesCount
                    htmlReportReady       = ($null -ne $script:lastHtmlReport -and (Test-Path $script:lastHtmlReport))
                    newLogs               = $newLogs
                    scannedPCs            = $script:scannedPCs
                    scanStep              = $script:scanStep
                    scanStepText          = $script:scanStepText
                    newSystemLogs         = $newSystemLogs
                    inAppSchedule         = @{
                        enabled         = $script:inAppSchedule.enabled
                        intervalMinutes = $script:inAppSchedule.intervalMinutes
                        intervalHours   = [math]::Round($script:inAppSchedule.intervalMinutes / 60, 2)
                        nextRunAt       = $nextRunStr
                        countdownSec    = $countdownSec
                    }
                    winTaskInfo           = $winTaskInfo
                }

                $json = $statusObj | ConvertTo-Json -Depth 5 -Compress
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/scan' -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $paramsObj = $body | ConvertFrom-Json

                # Convert PSCustomObject to Hashtable
                $scanParams = @{}
                foreach ($prop in $paramsObj.PSObject.Properties) {
                    $scanParams[$prop.Name] = $prop.Value
                }
                $script:lastScanParams = $scanParams

                try {
                    Start-ExecutionScan $scanParams | Out-Null
                    $json = @{ status = 'started' } | ConvertTo-Json
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.ContentLength64 = $buf.Length
                    $res.OutputStream.Write($buf, 0, $buf.Length)
                } catch {
                    $res.StatusCode = 400
                    $json = @{ error = $_.Exception.Message } | ConvertTo-Json
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = 'application/json; charset=utf-8'
                    $res.ContentLength64 = $buf.Length
                    $res.OutputStream.Write($buf, 0, $buf.Length)
                }
            }
            elseif ($path -eq '/api/schedule' -and $method -eq 'GET') {
                $winTaskInfo = Get-FtiWinTaskInfo
                $schedObj = @{
                    inAppSchedule = @{
                        enabled         = $script:inAppSchedule.enabled
                        intervalMinutes = $script:inAppSchedule.intervalMinutes
                        intervalHours   = [math]::Round($script:inAppSchedule.intervalMinutes / 60, 2)
                        nextRunAt       = if ($script:inAppSchedule.nextRunAt) { $script:inAppSchedule.nextRunAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
                    }
                    winTaskInfo   = $winTaskInfo
                }
                $json = $schedObj | ConvertTo-Json -Depth 5 -Compress
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/schedule' -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $params = $body | ConvertFrom-Json

                $action = [string]$params.action
                $msg = 'OK'

                if ($action -eq 'updateInApp') {
                    $enabled = [bool]$params.enabled
                    $intervalMins = 0
                    if ($params.intervalMinutes) {
                        $intervalMins = [int]$params.intervalMinutes
                    } elseif ($params.intervalHours) {
                        $intervalMins = [int]([double]$params.intervalHours * 60)
                    }
                    if ($intervalMins -lt 1) { $intervalMins = 240 }

                    $script:inAppSchedule.enabled = $enabled
                    $script:inAppSchedule.intervalMinutes = $intervalMins
                    if ($enabled) {
                        $script:inAppSchedule.nextRunAt = [System.DateTime]::Now.AddMinutes($intervalMins)
                    } else {
                        $script:inAppSchedule.nextRunAt = $null
                    }
                    $msg = "In-App schedule updated. Enabled=$enabled, Interval=$intervalMins minutes."
                }
                elseif ($action -eq 'registerWinTask') {
                    $mode = if ($params.mode) { [string]$params.mode } else { 'daily' }
                    $taskTime = if ($params.time) { [string]$params.time } else { '02:00' }
                    $intervalMins = if ($params.intervalMinutes) { [int]$params.intervalMinutes } else { 15 }
                    if ($intervalMins -lt 1) { $intervalMins = 1 }

                    $exe = Get-FtiExecutablePath
                    if (-not $exe) {
                        $res.StatusCode = 500
                        $json = @{ error = "Cannot find FTI_PC_Inventory.exe. Please build the application first." } | ConvertTo-Json
                        $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $res.ContentType = 'application/json; charset=utf-8'
                        $res.ContentLength64 = $buf.Length
                        $res.OutputStream.Write($buf, 0, $buf.Length)
                        continue
                    }

                    try {
                        $taskAction = New-ScheduledTaskAction -Execute $exe -Argument "-Silent -OutDir `"$($script:lastOutDir)`""
                        if ($mode -eq 'interval') {
                            $startStr = (Get-Date).ToString("HH:mm")
                            $trigger = New-ScheduledTaskTrigger -Once -At $startStr -RepetitionInterval (New-TimeSpan -Minutes $intervalMins) -RepetitionDuration (New-TimeSpan -Days 3650)
                            $msg = "Registered Windows Task 'FTI_PC_Inventory_AutoScan' repeating every $intervalMins minute(s). (Executable: $exe)"
                        } else {
                            $trigger = New-ScheduledTaskTrigger -Daily -At $taskTime
                            $msg = "Registered Windows Task 'FTI_PC_Inventory_AutoScan' at $taskTime daily. (Executable: $exe)"
                        }
                        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
                        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
                        Register-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
                    } catch {
                        $res.StatusCode = 500
                        $json = @{ error = "Failed to register Windows Task: $($_.Exception.Message)" } | ConvertTo-Json
                        $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $res.ContentType = 'application/json; charset=utf-8'
                        $res.ContentLength64 = $buf.Length
                        $res.OutputStream.Write($buf, 0, $buf.Length)
                        continue
                    }
                }
                elseif ($action -eq 'unregisterWinTask') {
                    try {
                        Unregister-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -Confirm:$false -ErrorAction Stop | Out-Null
                        $msg = "Windows Task 'FTI_PC_Inventory_AutoScan' removed."
                    } catch {
                        $res.StatusCode = 500
                        $json = @{ error = "Failed to remove Windows Task: $($_.Exception.Message)" } | ConvertTo-Json
                        $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $res.ContentType = 'application/json; charset=utf-8'
                        $res.ContentLength64 = $buf.Length
                        $res.OutputStream.Write($buf, 0, $buf.Length)
                        continue
                    }
                }
                elseif ($action -eq 'testRunWinTask') {
                    try {
                        $t = Get-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -ErrorAction SilentlyContinue
                        if (-not $t) {
                            throw "Task 'FTI_PC_Inventory_AutoScan' is not registered yet. Please register before testing."
                        }
                        Start-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan'
                        Start-Sleep -Seconds 2
                        $msg = "Test run triggered for Windows Task 'FTI_PC_Inventory_AutoScan'."
                    } catch {
                        $res.StatusCode = 500
                        $json = @{ error = "Failed to test run Windows Task: $($_.Exception.Message)" } | ConvertTo-Json
                        $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                        $res.ContentType = 'application/json; charset=utf-8'
                        $res.ContentLength64 = $buf.Length
                        $res.OutputStream.Write($buf, 0, $buf.Length)
                        continue
                    }
                }

                $json = @{ status = 'success'; message = $msg } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/master/status' -and $method -eq 'GET') {
                $outDirParam = $req.QueryString['outDir']
                if ([string]::IsNullOrWhiteSpace($outDirParam)) {
                    $outDirParam = if ($script:lastOutDir) { $script:lastOutDir } else { 'C:\Inventory' }
                }

                $hwMasterPath   = Join-Path $outDirParam 'Hardware_Master.csv'
                $swMasterPath   = Join-Path $outDirParam 'Software_Master.csv'
                $swSumPath      = Join-Path $outDirParam 'Software_Summary_Master.csv'

                $hwExists = Test-Path -LiteralPath $hwMasterPath
                $swExists = Test-Path -LiteralPath $swMasterPath
                $swSumExists = Test-Path -LiteralPath $swSumPath

                $hwInfo = @{ exists = $false; size = 0; lastModified = '-'; total = 0; ok = 0; offline = 0; error = 0 }
                $machines = [System.Collections.Generic.List[object]]::new()

                if ($hwExists) {
                    try {
                        $item = Get-Item -LiteralPath $hwMasterPath
                        $hwInfo.exists = $true
                        $hwInfo.size = "$([math]::Round($item.Length / 1KB, 1)) KB"
                        $hwInfo.lastModified = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')

                        $hwRows = @(Import-Csv -LiteralPath $hwMasterPath -Encoding UTF8)
                        $hwInfo.total = $hwRows.Count
                        $hwInfo.ok = @($hwRows | Where-Object { $_.Status -eq 'OK' }).Count
                        $hwInfo.offline = @($hwRows | Where-Object { $_.Status -match 'Offline' }).Count
                        $hwInfo.error = @($hwRows | Where-Object { $_.Status -match 'Error' }).Count

                        foreach ($r in $hwRows) {
                            $machines.Add(@{
                                PCName      = $r.PCName
                                Status      = $r.Status
                                IP          = $r.IP
                                OS          = $r.OS
                                User        = $r.User
                                CPU         = $r.CPU
                                RAM_GB      = $r.RAM_GB
                                Disk_C_Free = $r.Disk_C_Free
                                Last_Boot   = $r.Last_Boot
                                Scan_Count  = $r.Scan_Count
                                First_Seen  = $r.First_Seen
                                Last_Scan   = $r.Last_Scan
                            })
                        }
                    } catch {}
                }

                $swInfo = @{ exists = $false; size = 0; lastModified = '-'; totalRecords = 0; uniqueApps = 0 }
                if ($swExists) {
                    try {
                        $item = Get-Item -LiteralPath $swMasterPath
                        $swInfo.exists = $true
                        $swInfo.size = "$([math]::Round($item.Length / 1KB, 1)) KB"
                        $swInfo.lastModified = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                        $swRows = @(Import-Csv -LiteralPath $swMasterPath -Encoding UTF8)
                        $swInfo.totalRecords = $swRows.Count
                    } catch {}
                }
                if ($swSumExists) {
                    try {
                        $sumRows = @(Import-Csv -LiteralPath $swSumPath -Encoding UTF8)
                        $swInfo.uniqueApps = $sumRows.Count
                    } catch {}
                }

                # Check for backup files
                $backups = [System.Collections.Generic.List[object]]::new()
                try {
                    if (Test-Path -LiteralPath $outDirParam) {
                        $bFiles = Get-ChildItem -LiteralPath $outDirParam -Filter '*Master_Backup_*.csv' | Sort-Object LastWriteTime -Descending
                        foreach ($b in $bFiles) {
                            $backups.Add(@{
                                name         = $b.Name
                                size         = "$([math]::Round($b.Length / 1KB, 1)) KB"
                                lastModified = $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                            })
                        }
                    }
                } catch {}

                $masterResp = @{
                    outDir    = $outDirParam
                    hwMaster  = $hwInfo
                    swMaster  = $swInfo
                    machines  = $machines
                    backups   = $backups
                }

                $json = $masterResp | ConvertTo-Json -Depth 5 -Compress
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif (($path -eq '/api/master/action' -or $path -eq '/api/master/open' -or $path -eq '/api/master/backup') -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $params = if ($body) { $body | ConvertFrom-Json } else { @{} }
                $action = [string]$params.action
                if ($path -eq '/api/master/open') { $action = 'openFile' }
                elseif ($path -eq '/api/master/backup') { $action = 'backupMaster' }

                $outDirParam = [string]$params.outDir
                if ([string]::IsNullOrWhiteSpace($outDirParam)) {
                    $outDirParam = if ($script:lastOutDir) { $script:lastOutDir } else { 'C:\Inventory' }
                }

                $hwMasterPath = Join-Path $outDirParam 'Hardware_Master.csv'
                $swMasterPath = Join-Path $outDirParam 'Software_Master.csv'
                $swSumPath    = Join-Path $outDirParam 'Software_Summary_Master.csv'

                $resp = @{ status = 'OK'; message = '' }

                if ($action -eq 'openFile') {
                    $fileType = [string]$params.fileType # 'hw', 'sw', or 'swSum'
                    if ([string]::IsNullOrWhiteSpace($fileType)) { $fileType = [string]$params.type }
                    if ([string]::IsNullOrWhiteSpace($fileType)) { $fileType = 'hw' }
                    $targetPath = if ($fileType -eq 'sw') { $swMasterPath } elseif ($fileType -eq 'swSum') { $swSumPath } else { $hwMasterPath }
                    if (Test-Path -LiteralPath $targetPath) {
                        [System.Diagnostics.Process]::Start($targetPath) | Out-Null
                        $resp.message = "Opened $targetPath"
                    } else {
                        $res.StatusCode = 404
                        $resp.status = 'Error'
                        $resp.message = "File not found: $targetPath"
                    }
                }
                elseif ($action -eq 'backupMaster') {
                    $fileType = [string]$params.fileType
                    if ([string]::IsNullOrWhiteSpace($fileType)) { $fileType = [string]$params.type }
                    $stampBackup = Get-Date -Format 'yyyyMMdd_HHmmss'
                    $copiedCount = 0
                    $backupPath = $null
                    if ($fileType -eq 'sw') {
                        if (Test-Path -LiteralPath $swMasterPath) {
                            $destSw = Join-Path $outDirParam "Software_Master_Backup_$stampBackup.csv"
                            Copy-Item -LiteralPath $swMasterPath -Destination $destSw -Force
                            $copiedCount++
                            $backupPath = $destSw
                        }
                    } elseif ($fileType -eq 'swSum') {
                        if (Test-Path -LiteralPath $swSumPath) {
                            $destSwSum = Join-Path $outDirParam "Software_Summary_Backup_$stampBackup.csv"
                            Copy-Item -LiteralPath $swSumPath -Destination $destSwSum -Force
                            $copiedCount++
                            $backupPath = $destSwSum
                        }
                    } else {
                        if (Test-Path -LiteralPath $hwMasterPath) {
                            $destHw = Join-Path $outDirParam "Hardware_Master_Backup_$stampBackup.csv"
                            Copy-Item -LiteralPath $hwMasterPath -Destination $destHw -Force
                            $copiedCount++
                            $backupPath = $destHw
                        }
                        if (Test-Path -LiteralPath $swMasterPath -and -not $params.type) {
                            $destSw = Join-Path $outDirParam "Software_Master_Backup_$stampBackup.csv"
                            Copy-Item -LiteralPath $swMasterPath -Destination $destSw -Force
                            $copiedCount++
                        }
                    }
                    $resp.backupPath = $backupPath
                    $resp.message = "Created $copiedCount backup files (Timestamp: $stampBackup)"
                }
                elseif ($action -eq 'deleteMachine') {
                    $targetPC = [string]$params.pcName
                    if (-not [string]::IsNullOrWhiteSpace($targetPC)) {
                        $deletedHw = $false
                        if (Test-Path -LiteralPath $hwMasterPath) {
                            $rows = Import-Csv -LiteralPath $hwMasterPath -Encoding UTF8
                            $newRows = @($rows | Where-Object { $_.PCName.Trim().ToUpper() -ne $targetPC.Trim().ToUpper() })
                            if ($newRows.Count -lt $rows.Count) {
                                $newRows | Export-Csv -LiteralPath $hwMasterPath -NoTypeInformation -Encoding UTF8
                                $deletedHw = $true
                            }
                        }
                        if (Test-Path -LiteralPath $swMasterPath) {
                            $swRows = Import-Csv -LiteralPath $swMasterPath -Encoding UTF8
                            $newSwRows = @($swRows | Where-Object { $_.PCName.Trim().ToUpper() -ne $targetPC.Trim().ToUpper() })
                            if ($newSwRows.Count -lt $swRows.Count) {
                                $newSwRows | Export-Csv -LiteralPath $swMasterPath -NoTypeInformation -Encoding UTF8
                            }
                        }
                        $resp.message = "Deleted $targetPC from Master database."
                    }
                }
                elseif ($action -eq 'resetMaster') {
                    $stampBackup = Get-Date -Format 'yyyyMMdd_HHmmss'
                    if (Test-Path -LiteralPath $hwMasterPath) {
                        $destHw = Join-Path $outDirParam "Hardware_Master_Backup_$stampBackup.csv"
                        Copy-Item -LiteralPath $hwMasterPath -Destination $destHw -Force
                        Remove-Item -LiteralPath $hwMasterPath -Force
                    }
                    if (Test-Path -LiteralPath $swMasterPath) {
                        $destSw = Join-Path $outDirParam "Software_Master_Backup_$stampBackup.csv"
                        Copy-Item -LiteralPath $swMasterPath -Destination $destSw -Force
                        Remove-Item -LiteralPath $swMasterPath -Force
                    }
                    if (Test-Path -LiteralPath $swSumPath) {
                        Remove-Item -LiteralPath $swSumPath -Force -ErrorAction SilentlyContinue
                    }
                    $resp.message = "Master database reset successfully. (Safety backup saved: $stampBackup)"
                }

                $json = $resp | ConvertTo-Json -Depth 3 -Compress
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/system-log/clear' -and $method -eq 'POST') {
                $script:systemLogs.Clear()
                $script:sentSystemLogIndex = 0
                Write-SystemLog 'INFO' 'System log cleared by user.'
                $json = @{ status = 'cleared' } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/cancel' -and $method -eq 'POST') {
                if ($script:psInstance) {
                    $script:currentActivity = 'Cancelling scan by user request...'
                    $script:lastLogs.Add('[Cancelled] Scan stopped by user request.')
                    try { $script:psInstance.Stop() } catch {}
                }
                $json = @{ status = 'cancelled'; message = 'Scan cancelled by user.' } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif (($path -eq '/api/fs/list' -or $path -eq '/api/fs/browse') -and $method -eq 'GET') {
                $targetPath = $req.QueryString['path']
                $mode = $req.QueryString['mode'] # 'folder' or 'file'

                $drives = @()
                try {
                    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object {
                        @{
                            name       = $_.Name.TrimEnd('\')
                            root       = $_.RootDirectory.FullName
                            label      = if ($_.VolumeLabel) { "$($_.VolumeLabel) ($($_.Name.TrimEnd('\')))" } else { "Local Disk ($($_.Name.TrimEnd('\')))" }
                            totalBytes = $_.TotalSize
                            freeBytes  = $_.TotalFreeSpace
                        }
                    }
                } catch {}

                if ([string]::IsNullOrWhiteSpace($targetPath)) {
                    $targetPath = if (Test-Path 'C:\') { 'C:\' } elseif ($drives.Count -gt 0) { $drives[0].root } else { [System.Environment]::GetFolderPath('Desktop') }
                }

                if ($targetPath -match '^[a-zA-Z]:$') {
                    $targetPath = "$targetPath\"
                }

                $normPath = try { [System.IO.Path]::GetFullPath($targetPath) } catch { $targetPath }

                # If targetPath is actually a file, point to its containing directory
                if (Test-Path -LiteralPath $normPath -PathType Leaf) {
                    $normPath = try { [System.IO.Path]::GetDirectoryName($normPath) } catch { $normPath }
                }

                $parent = try {
                    $p = [System.IO.Directory]::GetParent($normPath)
                    if ($p) { $p.FullName } else { $null }
                } catch { $null }

                $items = @()
                $err = $null

                if (Test-Path -LiteralPath $normPath) {
                    try {
                        $dirInfo = New-Object System.IO.DirectoryInfo($normPath)
                        foreach ($sub in $dirInfo.GetDirectories()) {
                            if (($sub.Attributes -band [System.IO.FileAttributes]::Hidden) -or ($sub.Attributes -band [System.IO.FileAttributes]::System)) {
                                continue
                            }
                            $items += @{
                                name         = $sub.Name
                                fullPath     = $sub.FullName
                                path         = $sub.FullName
                                type         = 'folder'
                                isDir        = $true
                                lastModified = $sub.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                            }
                        }

                        if ($mode -eq 'file') {
                            foreach ($f in $dirInfo.GetFiles()) {
                                if (($f.Attributes -band [System.IO.FileAttributes]::Hidden) -or ($f.Attributes -band [System.IO.FileAttributes]::System)) {
                                    continue
                                }
                                $sizeFmt = if ($f.Length -ge 1048576) {
                                    "$([Math]::Round($f.Length / 1048576, 2)) MB"
                                } elseif ($f.Length -ge 1024) {
                                    "$([Math]::Round($f.Length / 1024, 1)) KB"
                                } else {
                                    "$($f.Length) B"
                                }
                                $items += @{
                                    name          = $f.Name
                                    fullPath      = $f.FullName
                                    path          = $f.FullName
                                    type          = 'file'
                                    isDir         = $false
                                    size          = $f.Length
                                    sizeFormatted = $sizeFmt
                                    lastModified  = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                                }
                            }
                        }
                    } catch {
                        $err = $_.Exception.Message
                    }
                } else {
                    $err = "Path not found: $normPath"
                }

                $result = @{
                    current      = $normPath
                    currentPath  = $normPath
                    parent       = $parent
                    parentPath   = $parent
                    drives       = $drives
                    driveLetters = ($drives | ForEach-Object { $_.name })
                    items        = $items
                    error        = $err
                }
                $json = $result | ConvertTo-Json -Depth 4
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/fs/mkdir' -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $params = $body | ConvertFrom-Json
                $parentPath = [string]$params.parent
                $folderName = [string]$params.name

                $success = $false
                $newPath = $null
                $err = $null

                try {
                    if ([string]::IsNullOrWhiteSpace($parentPath) -or -not (Test-Path -LiteralPath $parentPath)) {
                        $err = "Parent directory not found"
                    } elseif ([string]::IsNullOrWhiteSpace($folderName)) {
                        $err = "Folder name cannot be empty"
                    } else {
                        $cleanName = $folderName -replace '[\\/:*?"<>|]', ''
                        if ([string]::IsNullOrWhiteSpace($cleanName)) {
                            $err = "Invalid folder name"
                        } else {
                            $newPath = Join-Path $parentPath $cleanName
                            if (-not (Test-Path -LiteralPath $newPath)) {
                                [void](New-Item -ItemType Directory -Path $newPath -Force)
                            }
                            $success = $true
                        }
                    }
                } catch {
                    $err = $_.Exception.Message
                }

                $json = @{ success = $success; path = $newPath; error = $err } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/open-folder' -and $method -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $params = $body | ConvertFrom-Json
                $dir = if ($params.folder) { $params.folder } else { 'C:\Inventory' }

                if (-not (Test-Path $dir)) {
                    try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
                }
                [System.Diagnostics.Process]::Start('explorer.exe', $dir) | Out-Null

                $json = @{ status = 'opened' } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/open-report' -and $method -eq 'POST') {
                if ($script:lastHtmlReport -and (Test-Path $script:lastHtmlReport)) {
                    [System.Diagnostics.Process]::Start($script:lastHtmlReport) | Out-Null
                }
                $json = @{ status = 'opened' } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/exit') {
                $script:exitRequestedAt = [System.DateTime]::Now
                $json = @{ status = 'exit_scheduled' } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            else {
                $res.StatusCode = 404
                if ($path.StartsWith('/api/')) {
                    $json = @{ error = "API route not found: $path"; status = 404 } | ConvertTo-Json
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = 'application/json; charset=utf-8'
                } else {
                    $buf = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                    $res.ContentType = 'text/plain; charset=utf-8'
                }
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
        } catch {
            $res.StatusCode = 500
            if ($path.StartsWith('/api/')) {
                $json = @{ error = $_.Exception.Message; status = 500 } | ConvertTo-Json
                $errBuf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
            } else {
                $errBuf = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
                $res.ContentType = 'text/plain; charset=utf-8'
            }
            try {
                $res.ContentLength64 = $errBuf.Length
                $res.OutputStream.Write($errBuf, 0, $errBuf.Length)
            } catch {}
        } finally {
            $res.Close()
        }
    }
}

# --- 8. Cleanup on Exit ---
try {
    if ($listener.IsListening) {
        $listener.Stop()
        $listener.Close()
    }
} catch {}

if ($script:psInstance) {
    try { $script:psInstance.Stop() } catch {}
    try { $script:psInstance.Dispose() } catch {}
}
