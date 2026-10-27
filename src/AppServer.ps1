param(
    [switch]$Silent,
    [switch]$ScheduledRun,
    [string]$OutDir = 'C:\Inventory'
)

# --- 1. Resolve Core Engine & Web UI Assets ---
if (-not $CoreScript) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
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
    Write-Host "[FTI Inventory] Scheduled background run started at $(Get-Date)"
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $logFile = Join-Path $OutDir 'ScheduleRun.log'
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Scheduled scan triggered." | Out-File $logFile -Append -Encoding UTF8

    try {
        $coreParams = @{
            OutDir     = $OutDir
            MasterMode = $true
        }
        $res = & ([scriptblock]::Create($CoreScript)) @coreParams
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Scan completed successfully. Status=$($res.Status)" | Out-File $logFile -Append -Encoding UTF8
    } catch {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Scan failed: $($_.Exception.Message)" | Out-File $logFile -Append -Encoding UTF8
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

$script:lastInfoIndex   = 0
$script:lastWarnIndex   = 0
$script:lastErrIndex    = 0
$script:lastProgIndex   = 0
$script:sentLogIndex    = 0

# Scheduler State Tracking
$script:inAppSchedule = @{
    enabled       = $false
    intervalHours = 4
    nextRunAt     = $null
    lastRunAt     = $null
}
$script:lastScanParams = $null
$script:lastOutDir = 'C:\Inventory'

# --- 5. Background Stream Pump Function ---
function Update-ScanProgress() {
    if (-not $script:psInstance) { return }

    $streams = $script:psInstance.Streams

    # 1. Information Stream
    if ($streams.Information.Count -gt $script:lastInfoIndex) {
        for ($i = $script:lastInfoIndex; $i -lt $streams.Information.Count; $i++) {
            $msg = $streams.Information[$i].MessageData.ToString()
            $script:lastLogs.Add($msg)

            if ($msg -match 'Computers to scan:\s+(\d+)') {
                $script:total = [int]$Matches[1]
            }
            elseif ($msg -match 'Software done\.\s+OK:\s+(\d+)') {
                $script:ok = [int]$Matches[1]
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
                                    User         = if ($row.User) { $row.User } else { '-' }
                                    Maker        = if ($row.Maker) { $row.Maker } else { '-' }
                                    Model        = if ($row.Model) { $row.Model } else { '-' }
                                    CPU          = if ($row.CPU) { $row.CPU } else { '-' }
                                    RAM_GB       = if ($row.RAM_GB) { $row.RAM_GB } else { '-' }
                                    Disk_C_Free  = if ($row.Disk_C_Free) { $row.Disk_C_Free } else { '-' }
                                    OS           = if ($row.OS) { $row.OS } else { '-' }
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
    [void]$script:psInstance.AddParameter('MasterMode', $isMaster)
    [void]$script:psInstance.AddParameter('RetryOfflineOnly', $isRetryOffline)

    if ($params.source -eq 'localhost') {
        [void]$script:psInstance.AddParameter('ScanLocalhost', $true)
    }
    elseif ($params.source -eq 'file' -and $params.listFile) {
        [void]$script:psInstance.AddParameter('ComputerListFile', [string]$params.listFile)
    }

    $script:asyncResult = $script:psInstance.BeginInvoke()
    return $true
}

# --- 6. Launch Standalone Edge App Window ---
$edgePaths = @(
    "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
)
$edgeExe = $edgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

$tempProfile = Join-Path $env:TEMP 'fti_inventory_web_profile'
if (-not (Test-Path $tempProfile)) {
    New-Item -ItemType Directory -Path $tempProfile -Force | Out-Null
}

$appUrl = "http://127.0.0.1:$port/"
$appArgs = "--app=`"$appUrl`" --user-data-dir=`"$tempProfile`" --window-size=1260,860"

if ($edgeExe) {
    Start-Process -FilePath $edgeExe -ArgumentList $appArgs | Out-Null
} else {
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
    if ($script:inAppSchedule.enabled -and -not $scanRunning -and $script:inAppSchedule.nextRunAt) {
        if ([System.DateTime]::Now -ge $script:inAppSchedule.nextRunAt) {
            $script:inAppSchedule.lastRunAt = [System.DateTime]::Now
            $script:inAppSchedule.nextRunAt = [System.DateTime]::Now.AddHours($script:inAppSchedule.intervalHours)
            $script:lastLogs.Add("[Scheduler] Auto-scan triggered at $(Get-Date -Format 'HH:mm:ss')")
            
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
                $winTaskInfo = @{ registered = $false; state = 'NotRegistered'; time = '02:00' }
                try {
                    $t = Get-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -ErrorAction SilentlyContinue
                    if ($t) {
                        $winTaskInfo.registered = $true
                        $winTaskInfo.state = $t.State.ToString()
                        if ($t.Triggers -and $t.Triggers[0] -and $t.Triggers[0].StartBoundary) {
                            $winTaskInfo.time = ([datetime]$t.Triggers[0].StartBoundary).ToString('HH:mm')
                        }
                    }
                } catch {}

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
                    inAppSchedule         = @{
                        enabled       = $script:inAppSchedule.enabled
                        intervalHours = $script:inAppSchedule.intervalHours
                        nextRunAt     = $nextRunStr
                        countdownSec  = $countdownSec
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
                $winTaskInfo = @{ registered = $false; state = 'NotRegistered'; time = '02:00' }
                try {
                    $t = Get-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -ErrorAction SilentlyContinue
                    if ($t) {
                        $winTaskInfo.registered = $true
                        $winTaskInfo.state = $t.State.ToString()
                        if ($t.Triggers -and $t.Triggers[0] -and $t.Triggers[0].StartBoundary) {
                            $winTaskInfo.time = ([datetime]$t.Triggers[0].StartBoundary).ToString('HH:mm')
                        }
                    }
                } catch {}

                $schedObj = @{
                    inAppSchedule = $script:inAppSchedule
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
                    $interval = [int]$params.intervalHours
                    if ($interval -le 0) { $interval = 4 }
                    $script:inAppSchedule.enabled = $enabled
                    $script:inAppSchedule.intervalHours = $interval
                    if ($enabled) {
                        $script:inAppSchedule.nextRunAt = [System.DateTime]::Now.AddHours($interval)
                    } else {
                        $script:inAppSchedule.nextRunAt = $null
                    }
                    $msg = "In-App schedule updated. Enabled=$enabled, Interval=$interval hours."
                }
                elseif ($action -eq 'registerWinTask') {
                    $taskTime = if ($params.time) { [string]$params.time } else { '02:00' }
                    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                    if ($exePath -match 'powershell\.exe') {
                        $exePath = 'E:\FTI_PC_Inventory.exe'
                    }

                    try {
                        $taskAction = New-ScheduledTaskAction -Execute $exePath -Argument "-Silent -OutDir `"$($script:lastOutDir)`""
                        $trigger = New-ScheduledTaskTrigger -Daily -At $taskTime
                        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
                        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
                        Register-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
                        $msg = "Registered Windows Task 'FTI_PC_Inventory_AutoScan' at $taskTime daily."
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
                        Unregister-ScheduledTask -TaskName 'FTI_PC_Inventory_AutoScan' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
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

                $json = @{ status = 'success'; message = $msg } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/cancel' -and $method -eq 'POST') {
                if ($script:psInstance) {
                    try { $script:psInstance.Stop() } catch {}
                    $script:lastLogs.Add('[Cancelled] Scan stopped by user.')
                }
                $json = @{ status = 'cancelled' } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/fs/list' -and $method -eq 'GET') {
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

                $normPath = try { [System.IO.Path]::GetFullPath($targetPath) } catch { $targetPath }
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
                                type         = 'folder'
                                lastModified = $sub.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                            }
                        }

                        if ($mode -eq 'file') {
                            foreach ($f in $dirInfo.GetFiles()) {
                                if (($f.Attributes -band [System.IO.FileAttributes]::Hidden) -or ($f.Attributes -band [System.IO.FileAttributes]::System)) {
                                    continue
                                }
                                $items += @{
                                    name         = $f.Name
                                    fullPath     = $f.FullName
                                    type         = 'file'
                                    size         = $f.Length
                                    lastModified = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
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
                    current = $normPath
                    parent  = $parent
                    drives  = $drives
                    items   = $items
                    error   = $err
                }
                $json = $result | ConvertTo-Json -Depth 3
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
                $buf = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
        } catch {
            $res.StatusCode = 500
            $errBuf = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
            try { $res.OutputStream.Write($errBuf, 0, $errBuf.Length) } catch {}
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
