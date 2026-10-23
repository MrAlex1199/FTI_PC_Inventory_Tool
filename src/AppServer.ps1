# ==============================================================================
# FTI PC Inventory Tool - Web Application Engine (Edge App Host + Local Server)
# ==============================================================================

Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

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

# --- 4. Global State Tracking ---
$script:psInstance      = $null
$script:asyncResult     = $null
$script:scanStartTime   = $null
$script:isCompleted     = $false
$script:percent         = 0
$script:total           = 0
$script:ok              = 0
$script:offline         = 0
$script:errCount        = 0
$script:currentActivity = 'พร้อมทำงาน'
$script:lastHtmlReport  = $null
$script:autoOpenHtml    = $true
$script:lastLogs        = [System.Collections.Generic.List[string]]::new()
$script:scannedPCs      = [System.Collections.Generic.List[hashtable]]::new()

$script:lastInfoIndex   = 0
$script:lastWarnIndex   = 0
$script:lastErrIndex    = 0
$script:lastProgIndex   = 0
$script:sentLogIndex    = 0

# --- Helper: Thread-Safe Native Dialogs ---
function Show-NativeFileDialog() {
    $selected = ''
    $dummy = $null
    $dlg = $null
    try {
        $dummy = New-Object System.Windows.Forms.Form
        $dummy.TopMost = $true
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $dlg.Title = 'Select PC List File'
        if ($dlg.ShowDialog($dummy) -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = $dlg.FileName
        }
    } catch { }
    finally {
        if ($dlg) { $dlg.Dispose() }
        if ($dummy) { $dummy.Dispose() }
    }
    return $selected
}

function Show-NativeFolderDialog([string]$initialPath) {
    $selected = ''
    $dummy = $null
    $dlg = $null
    try {
        $dummy = New-Object System.Windows.Forms.Form
        $dummy.TopMost = $true
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select Output Directory'
        $dlg.ShowNewFolderButton = $true
        if ($initialPath -and (Test-Path $initialPath)) {
            $dlg.SelectedPath = $initialPath
        }
        if ($dlg.ShowDialog($dummy) -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = $dlg.SelectedPath
        }
    } catch { }
    finally {
        if ($dlg) { $dlg.Dispose() }
        if ($dummy) { $dummy.Dispose() }
    }
    return $selected
}

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
                        PCName  = $pcName
                        Status  = 'Scanning'
                        CPU     = '...'
                        RAM_GB  = ''
                        OS      = '...'
                        IP      = '...'
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
        $script:currentActivity = 'การสแกนเสร็จสิ้น'

        try {
            $res = $script:psInstance.EndInvoke($script:asyncResult)
            if ($res -and $res.Count -gt 0) {
                $lastObj = $res[$res.Count - 1]
                if ($lastObj -and $lastObj.SoftwareHtml) {
                    $script:lastHtmlReport = $lastObj.SoftwareHtml
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

        # Auto open HTML report if enabled
        if ($script:autoOpenHtml -and $script:lastHtmlReport -and (Test-Path $script:lastHtmlReport)) {
            try {
                [System.Diagnostics.Process]::Start($script:lastHtmlReport) | Out-Null
                $script:lastLogs.Add("Auto-opened report: $script:lastHtmlReport")
            } catch {}
        }
    }
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

# --- 7. Main HTTP Request Loop with Heartbeat Lifecycle ---
$script:lastHeartbeat = [System.DateTime]::Now
$script:hasConnected = $false
$running = $true
$pendingAsync = $null

while ($running) {
    # Pump scan streams
    Update-ScanProgress

    # Exit if browser was closed (after initial connection established, timeout after 15 seconds of no requests)
    if ($script:hasConnected) {
        if (([System.DateTime]::Now - $script:lastHeartbeat).TotalSeconds -gt 15) {
            $running = $false
            break
        }
    } else {
        # Allow 45 seconds for user/browser to launch
        if (([System.DateTime]::Now - $script:lastHeartbeat).TotalSeconds -gt 45) {
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
                    $ts = [System.DateTime]::Now - $script:scanStartTime
                    $elapsedStr = $ts.ToString('mm\:ss')
                }

                $newLogs = @()
                if ($script:lastLogs.Count -gt $script:sentLogIndex) {
                    $newLogs = @($script:lastLogs.GetRange($script:sentLogIndex, ($script:lastLogs.Count - $script:sentLogIndex)))
                    $script:sentLogIndex = $script:lastLogs.Count
                }

                $statusObj = @{
                    isAdmin         = $isAdmin
                    isScanning      = ($null -ne $script:psInstance)
                    isCompleted     = $script:isCompleted
                    percent         = $script:percent
                    elapsed         = $elapsedStr
                    currentActivity = $script:currentActivity
                    total           = $script:total
                    ok              = $script:ok
                    offline         = $script:offline
                    error           = $script:errCount
                    htmlReportReady = ($null -ne $script:lastHtmlReport -and (Test-Path $script:lastHtmlReport))
                    newLogs         = $newLogs
                    scannedPCs      = $script:scannedPCs
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
                $params = $body | ConvertFrom-Json

                # Reset state
                $script:isCompleted     = $false
                $script:percent         = 0
                $script:total           = 0
                $script:ok              = 0
                $script:offline         = 0
                $script:errCount        = 0
                $script:currentActivity = 'กำลังเตรียมการสแกน...'
                $script:lastHtmlReport  = $null
                $script:autoOpenHtml    = [bool]$params.autoHtml
                $script:lastLogs.Clear()
                $script:scannedPCs.Clear()
                $script:lastInfoIndex   = 0
                $script:lastWarnIndex   = 0
                $script:lastErrIndex    = 0
                $script:lastProgIndex   = 0
                $script:sentLogIndex    = 0
                $script:scanStartTime   = [System.DateTime]::Now

                # Create Background Runspace
                $script:psInstance = [powershell]::Create()
                [void]$script:psInstance.AddScript($CoreScript)

                $isHw = [bool]$params.scanHw
                $isSw = [bool]$params.scanSw
                [void]$script:psInstance.AddParameter('NoSoftware', (-not $isSw))
                [void]$script:psInstance.AddParameter('SkipHardware', (-not $isHw))
                [void]$script:psInstance.AddParameter('NameFilter', [string]$params.nameFilter)
                [void]$script:psInstance.AddParameter('IncludeUserInstalls', [bool]$params.includeUser)
                [void]$script:psInstance.AddParameter('IncludeHidden', [bool]$params.includeHidden)
                [void]$script:psInstance.AddParameter('DaysActive', [int]$params.daysActive)
                [void]$script:psInstance.AddParameter('Throttle', [int]$params.throttle)
                [void]$script:psInstance.AddParameter('OutDir', [string]$params.outDir)

                if ($params.source -eq 'localhost') {
                    [void]$script:psInstance.AddParameter('ScanLocalhost', $true)
                }
                elseif ($params.source -eq 'file' -and $params.listFile) {
                    [void]$script:psInstance.AddParameter('ComputerListFile', [string]$params.listFile)
                }

                $script:asyncResult = $script:psInstance.BeginInvoke()

                $json = @{ status = 'started' } | ConvertTo-Json
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
            elseif ($path -eq '/api/browse-file' -and $method -eq 'POST') {
                $chosenFile = Show-NativeFileDialog
                $json = @{ file = $chosenFile } | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
            elseif ($path -eq '/api/browse-folder' -and $method -eq 'POST') {
                $chosenFolder = Show-NativeFolderDialog 'C:\Inventory'
                $json = @{ folder = $chosenFolder } | ConvertTo-Json
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
                $running = $false
                $json = @{ status = 'exiting' } | ConvertTo-Json
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
