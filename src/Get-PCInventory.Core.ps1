<#
.SYNOPSIS
  PC inventory for domain PCs: Hardware + Installed Software (both ON by default). PowerShell 5.1, read-only.
  Core engine module for FTI PC Inventory Tool.
#>
param(
    [switch]$Software,               # kept for compatibility: software scan is ON by default
    [switch]$NoSoftware,             # use this to skip the software scan
    [switch]$SkipHardware,
    [string]$NameFilter = '*',
    [switch]$IncludeUserInstalls,
    [switch]$IncludeHidden,          # include system components + Windows updates in software list
    [string]$ComputerListFile,
    [int]$DaysActive = 30,           # only PCs that logged on to the domain within N days (AD mode, 0 = all)
    [int]$Throttle = 20,
    [string]$OutDir = 'C:\Inventory',
    [switch]$FallbackToAD,           # If ComputerListFile is empty, fallback to AD if set
    [switch]$ScanLocalhost,          # Scan current machine directly
    [switch]$MasterMode = $true,     # Sync with Master Database (Hardware_Master.csv)
    [switch]$RetryOfflineOnly,       # Filter target to PCs that are Offline/Error in Master file
    [string]$MasterFile,             # Custom path to Hardware Master CSV (defaults to OutDir\Hardware_Master.csv)
    [string]$SoftwareMasterFile,     # Custom path to Software Master CSV (defaults to OutDir\Software_Master.csv)
    [switch]$SkipServers = $true,    # Skip Servers, DCs, RDS, and Remote servers (PC / Notebooks only)
    [string]$ExcludeServerFile       # Optional .txt file with hostnames/IPs to exclude from scan
)

$Software = -not $NoSoftware

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

if (-not $MasterFile) {
    $MasterFile = Join-Path $OutDir 'Hardware_Master.csv'
}
if (-not $SoftwareMasterFile) {
    $SoftwareMasterFile = Join-Path $OutDir 'Software_Master.csv'
}

$fHw = $null
$fByPC = $null
$fSoft = $null
$fSoftMaster = $null
$fSumMaster = $null

# --- Helper: Standardized Hardware Record Schema ---
function New-HardwareRecord([hashtable]$h) {
    return [pscustomobject][ordered]@{
        PCName         = if ($h.ContainsKey('PCName') -and $h.PCName) { [string]$h.PCName } else { '-' }
        Status         = if ($h.ContainsKey('Status') -and $h.Status) { [string]$h.Status } else { 'OK' }
        Status_Detail  = if ($h.ContainsKey('Status_Detail') -and $h.Status_Detail) { [string]$h.Status_Detail } else { '' }
        Fail_Count     = if ($h.ContainsKey('Fail_Count') -and $null -ne $h.Fail_Count) { [int]$h.Fail_Count } else { 0 }
        Win_License    = if ($h.ContainsKey('Win_License') -and $h.Win_License) { [string]$h.Win_License } else { '-' }
        Office_License = if ($h.ContainsKey('Office_License') -and $h.Office_License) { [string]$h.Office_License } else { '-' }
        Office_Detail  = if ($h.ContainsKey('Office_Detail') -and $h.Office_Detail) { [string]$h.Office_Detail } else { '-' }
        User           = if ($h.ContainsKey('User') -and $h.User) { [string]$h.User } else { '-' }
        Maker          = if ($h.ContainsKey('Maker') -and $h.Maker) { [string]$h.Maker } else { '-' }
        Model          = if ($h.ContainsKey('Model') -and $h.Model) { [string]$h.Model } else { '-' }
        Serial         = if ($h.ContainsKey('Serial') -and $h.Serial) { [string]$h.Serial } else { '-' }
        CPU            = if ($h.ContainsKey('CPU') -and $h.CPU) { [string]$h.CPU } else { '-' }
        Cores          = if ($h.ContainsKey('Cores') -and $h.Cores) { [string]$h.Cores } else { '-' }
        RAM_GB         = if ($h.ContainsKey('RAM_GB') -and $h.RAM_GB) { [string]$h.RAM_GB } else { '-' }
        Disk_C_Free    = if ($h.ContainsKey('Disk_C_Free') -and $h.Disk_C_Free) { [string]$h.Disk_C_Free } else { '-' }
        Disks          = if ($h.ContainsKey('Disks') -and $h.Disks) { [string]$h.Disks } else { '-' }
        GPU            = if ($h.ContainsKey('GPU') -and $h.GPU) { [string]$h.GPU } else { '-' }
        OS             = if ($h.ContainsKey('OS') -and $h.OS) { [string]$h.OS } else { '-' }
        OSBuild        = if ($h.ContainsKey('OSBuild') -and $h.OSBuild) { [string]$h.OSBuild } else { '-' }
        Last_Boot      = if ($h.ContainsKey('Last_Boot') -and $h.Last_Boot) { [string]$h.Last_Boot } else { '-' }
        Uptime         = if ($h.ContainsKey('Uptime') -and $h.Uptime) { [string]$h.Uptime } else { '-' }
        AD_LastLogon   = if ($h.ContainsKey('AD_LastLogon') -and $h.AD_LastLogon) { [string]$h.AD_LastLogon } else { '-' }
        AD_OU          = if ($h.ContainsKey('AD_OU') -and $h.AD_OU) { [string]$h.AD_OU } else { '-' }
        IP             = if ($h.ContainsKey('IP') -and $h.IP) { [string]$h.IP } else { '-' }
        MAC            = if ($h.ContainsKey('MAC') -and $h.MAC) { [string]$h.MAC } else { '-' }
        Scan_Count     = if ($h.ContainsKey('Scan_Count') -and $h.Scan_Count) { [string]$h.Scan_Count } else { '1' }
        First_Seen     = if ($h.ContainsKey('First_Seen') -and $h.First_Seen) { [string]$h.First_Seen } else { '-' }
        Last_Scan      = if ($h.ContainsKey('Last_Scan') -and $h.Last_Scan) { [string]$h.Last_Scan } else { '-' }
    }
}

# --- Helper: Parse Office License & Channel ---
function Parse-OfficeLicenseInfo([string]$c2rProd, $slpList) {
    $foundName = ''
    $foundChan = ''
    $foundStatus = ''

    if ($slpList -and $slpList.Count -gt 0) {
        foreach ($p in $slpList) {
            $name = [string]$p.Name
            $chan = [string]$p.ProductKeyChannel
            $stat = [int]$p.LicenseStatus # 1=Licensed, 5/2=Grace, 0=Unlicensed

            $edition = if ($name -match 'Office\s*(\d+)') {
                "Office " + $Matches[1]
            } elseif ($name -match 'Office16|Office 16') {
                "Office 2016"
            } elseif ($name -match 'Office19|Office 19') {
                "Office 2019"
            } elseif ($name -match 'Office21|Office 21') {
                "Office 2021"
            } elseif ($name -match 'Office24|Office 24') {
                "Office 2024"
            } else {
                "Office"
            }

            $chType = if ($chan -match '(?i)KMS|GVLK') {
                'KMS'
            } elseif ($chan -match '(?i)MAK') {
                'MAK'
            } elseif ($chan -match '(?i)OEM') {
                'OEM'
            } elseif ($chan -match '(?i)RETAIL') {
                'Retail'
            } else {
                'Volume'
            }

            $stText = if ($stat -eq 1) { 'Activated' } elseif ($stat -eq 5 -or $stat -eq 2) { 'Grace' } else { 'Unlicensed' }

            if ($stat -eq 1 -or -not $foundName) {
                $foundName = $edition
                $foundChan = $chType
                $foundStatus = $stText
                if ($stat -eq 1) { break }
            }
        }
    }

    if ($foundName) {
        $shortEdition = $foundName -replace '^Office\s*', ''
        $badge = if ($foundStatus -eq 'Activated') {
            "$shortEdition $foundChan"
        } else {
            "$shortEdition ($foundStatus)"
        }
        $detail = "$foundName - $foundChan ($foundStatus)"
        return @{ Badge = $badge; Detail = $detail }
    }

    if ($c2rProd) {
        if ($c2rProd -match 'O365|M365|Microsoft365') {
            return @{ Badge = 'M365 (Act)'; Detail = "Microsoft 365 ($c2rProd)" }
        } elseif ($c2rProd -match '2021') {
            return @{ Badge = '2021 (C2R)'; Detail = "Office 2021 Click-to-Run ($c2rProd)" }
        } elseif ($c2rProd -match '2019') {
            return @{ Badge = '2019 (C2R)'; Detail = "Office 2019 Click-to-Run ($c2rProd)" }
        } elseif ($c2rProd -match 'ProPlus|Standard') {
            return @{ Badge = 'Office C2R'; Detail = "Office Click-to-Run ($c2rProd)" }
        }
    }

    return @{ Badge = 'None'; Detail = 'No Microsoft Office installation detected' }
}

# --- Helper: Smart Connectivity Check (ICMP Ping + TCP 5985/135 Fallback) ---
function Test-PCConnection([string]$computer) {
    if ($computer -eq 'localhost' -or $computer -eq '127.0.0.1' -or $computer -eq $env:COMPUTERNAME) {
        return $true
    }
    # 1. Quick ICMP ping
    if (Test-Connection -ComputerName $computer -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        return $true
    }
    # 2. Smart Port Check: WinRM 5985 or RPC 135 (prevents false Offline if ICMP blocked)
    foreach ($port in 5985, 135) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($computer, $port, $null, $null)
            $wait = $ar.AsyncWaitHandle.WaitOne(800)
            if ($wait -and $tcp.Connected) {
                $tcp.EndConnect($ar)
                $tcp.Close()
                return $true
            }
            $tcp.Close()
        } catch { }
    }
    return $false
}

# --- Cache and Helper for Active Directory metadata (Logon, OU) ---
$adCache = @{}

function Get-ADInfo([string]$pc) {
    if ($adCache.ContainsKey($pc.ToUpper())) {
        return $adCache[$pc.ToUpper()]
    }
    try {
        $searcher = [adsisearcher]"(&(objectCategory=computer)(name=$pc))"
        [void]$searcher.PropertiesToLoad.Add('lastlogontimestamp')
        [void]$searcher.PropertiesToLoad.Add('distinguishedname')
        $one = $searcher.FindOne()
        if ($one) {
            $lastLogonStr = '-'
            if ($one.Properties.Contains('lastlogontimestamp')) {
                try {
                    $ft = [int64]$one.Properties['lastlogontimestamp'][0]
                    if ($ft -gt 0) {
                        $lastLogonStr = [datetime]::FromFileTime($ft).ToString('yyyy-MM-dd HH:mm')
                    }
                } catch {}
            }
            $ouStr = '-'
            if ($one.Properties.Contains('distinguishedname')) {
                try {
                    $dn = [string]$one.Properties['distinguishedname'][0]
                    $ous = [regex]::Matches($dn, 'OU=([^,]+)') | ForEach-Object { $_.Groups[1].Value }
                    if ($ous.Count -gt 0) {
                        $ouArr = @($ous)
                        [array]::Reverse($ouArr)
                        $ouStr = $ouArr -join ' / '
                    }
                } catch {}
            }
            $info = @{ AD_LastLogon = $lastLogonStr; AD_OU = $ouStr }
            $adCache[$pc.ToUpper()] = $info
            return $info
        }
    } catch {}
    return @{ AD_LastLogon = '-'; AD_OU = '-' }
}

# --- Server & Exclusion List Set ---
$excludedHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($ExcludeServerFile -and (Test-Path -LiteralPath $ExcludeServerFile)) {
    try {
        $exLines = Get-Content -LiteralPath $ExcludeServerFile -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' } |
            ForEach-Object { $_.Trim() }
        foreach ($h in $exLines) {
            [void]$excludedHosts.Add($h)
        }
        Write-Host ('Loaded ' + $excludedHosts.Count + ' machines to exclude from file: ' + $ExcludeServerFile) -ForegroundColor Cyan
    } catch {
        Write-Warning ('Could not read exclusion file: ' + $_.Exception.Message)
    }
}

Write-Host '[STEP:1] Target Discovery and Server Filtering...' -ForegroundColor Cyan

# ================= 1) Computer list (works without RSAT) =================
$pcs = @()

if ($RetryOfflineOnly) {
    Write-Host '--- Retry Offline Mode Activated ---' -ForegroundColor Yellow
    if (Test-Path -LiteralPath $MasterFile) {
        try {
            $masterRows = Import-Csv -LiteralPath $MasterFile -Encoding UTF8
            $offlineList = @($masterRows | Where-Object { $_.Status -match 'Offline|Error' } | ForEach-Object { [string]$_.PCName.Trim() } | Where-Object { $_ } | Select-Object -Unique)
            if ($offlineList.Count -gt 0) {
                Write-Host "Targeting only previously Offline/Error computers from Master: $($offlineList.Count) PCs" -ForegroundColor Yellow
                $pcs = $offlineList
            } else {
                Write-Host 'No offline or error computers found in Master database to retry.' -ForegroundColor Green
                return [pscustomobject]@{
                    Status       = 'Empty'
                    Message      = 'No offline or error computers found in Master database to retry.'
                    OutDir       = $OutDir
                    HardwareCsv  = $null
                    MasterCsv    = $MasterFile
                    SoftwareHtml = $null
                    SoftwareCsv  = $null
                    Timestamp    = $stamp
                }
            }
        } catch {
            Write-Warning "Could not read Master database for offline retry: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Master file ($MasterFile) does not exist yet. Cannot perform offline retry."
        return [pscustomobject]@{
            Status       = 'Empty'
            Message      = "Master file ($MasterFile) does not exist yet. Please run a regular scan first."
            OutDir       = $OutDir
            HardwareCsv  = $null
            MasterCsv    = $MasterFile
            SoftwareHtml = $null
            SoftwareCsv  = $null
            Timestamp    = $stamp
        }
    }
}
elseif ($ScanLocalhost) {
    $pcs = @($env:COMPUTERNAME)
}
elseif ($ComputerListFile) {
    if (-not (Test-Path $ComputerListFile)) {
        Write-Warning "List file not found: $ComputerListFile"
        return [pscustomobject]@{ Status = 'Error'; Message = "List file not found: $ComputerListFile" }
    }
    $pcs = @(Get-Content $ComputerListFile | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' } | ForEach-Object { $_.Trim() })
    if ($pcs.Count -eq 0) {
        Write-Warning "List file is empty: $ComputerListFile"
        if ($FallbackToAD) {
            # continue to AD below
        } else {
            Write-Host 'Cancelled.'
            return [pscustomobject]@{ Status = 'Cancelled'; Message = 'List file is empty and FallbackToAD was not requested.' }
        }
    }
}

if (-not $RetryOfflineOnly -and -not $ScanLocalhost -and ($pcs.Count -eq 0)) {
    # Active Directory mode
    try {
        $filterParts = @("objectCategory=computer", "operatingSystem=*Windows*", "!(userAccountControl:1.2.840.113556.1.4.803:=2)")
        if ($SkipServers) {
            $filterParts += "!(operatingSystem=*Server*)"
            $filterParts += "!(operatingSystem=*Domain Controller*)"
        }
        if ($DaysActive -gt 0) {
            $ft = (Get-Date).AddDays(-$DaysActive).ToFileTime()
            $filterParts += "lastLogonTimestamp>=$ft"
        }
        $ldapFilter = "(&(" + ($filterParts -join ")(") + "))"
        $ds = [adsisearcher]$ldapFilter
        $ds.PageSize = 1000
        [void]$ds.PropertiesToLoad.Add('name')
        [void]$ds.PropertiesToLoad.Add('lastlogontimestamp')
        [void]$ds.PropertiesToLoad.Add('distinguishedname')
        
        $adResults = $ds.FindAll()
        $filteredPCs = [System.Collections.Generic.List[string]]::new()
        foreach ($res in $adResults) {
            $cName = [string]$res.Properties['name'][0]
            if ($cName) {
                $dnRaw = if ($res.Properties.Contains('distinguishedname')) { [string]$res.Properties['distinguishedname'][0] } else { '' }
                
                # Check Server & Remote Server name/OU patterns
                if ($excludedHosts.Contains($cName)) {
                    Write-Host "  [SKIP EXCLUDED FILE] $cName" -ForegroundColor Gray
                    continue
                }
                if ($SkipServers) {
                    $isServerName = ($cName -match '(?i)(^|[-_])(SRV|SERVER|DC|RDS|RDP|REMOTE|HYPERV|VHOST|ESX)([-_]|\d|$)')
                    $isServerOU   = ($dnRaw -match '(?i)OU=(Domain Controllers|Servers|Server|Infrastructure)')
                    if ($isServerName -or $isServerOU) {
                        Write-Host "  [SKIP SERVER] $cName (OU: $dnRaw)" -ForegroundColor Gray
                        continue
                    }
                }

                $lastLogonStr = '-'
                if ($res.Properties.Contains('lastlogontimestamp')) {
                    try {
                        $ft = [int64]$res.Properties['lastlogontimestamp'][0]
                        if ($ft -gt 0) {
                            $lastLogonStr = [datetime]::FromFileTime($ft).ToString('yyyy-MM-dd HH:mm')
                        }
                    } catch {}
                }
                $ouStr = '-'
                if ($res.Properties.Contains('distinguishedname')) {
                    try {
                        $ous = [regex]::Matches($dnRaw, 'OU=([^,]+)') | ForEach-Object { $_.Groups[1].Value }
                        if ($ous.Count -gt 0) {
                            $ouArr = @($ous)
                            [array]::Reverse($ouArr)
                            $ouStr = $ouArr -join ' / '
                        }
                    } catch {}
                }
                $adCache[$cName.ToUpper()] = @{
                    AD_LastLogon = $lastLogonStr
                    AD_OU        = $ouStr
                }
                $filteredPCs.Add($cName)
            }
        }
        $pcs = @($filteredPCs | Sort-Object)
    } catch {
        Write-Warning "Active Directory query error: $($_.Exception.Message)"
        return [pscustomobject]@{ Status = 'Error'; Message = "Active Directory query error: $($_.Exception.Message)" }
    }
}

# Apply server name filter for file list or offline retry if SkipServers is ON
if ($SkipServers -and $pcs.Count -gt 0 -and -not $ScanLocalhost) {
    $beforeCount = $pcs.Count
    $pcs = @($pcs | Where-Object { $_ -notmatch '(?i)(^|[-_])(SRV|SERVER|DC|RDS|RDP|REMOTE|HYPERV|VHOST|ESX)([-_]|\d|$)' })
    $diff = $beforeCount - $pcs.Count
    if ($diff -gt 0) {
        Write-Host "Filtered out $diff Server/Remote machines by name pattern. Remaining: $($pcs.Count) PCs" -ForegroundColor Yellow
    }
}

if ($excludedHosts.Count -gt 0 -and $pcs.Count -gt 0 -and -not $ScanLocalhost) {
    $beforeEx = $pcs.Count
    $pcs = @($pcs | Where-Object { -not $excludedHosts.Contains($_) })
    $diffEx = $beforeEx - $pcs.Count
    if ($diffEx -gt 0) {
        Write-Host "Filtered out $diffEx machines matching exclusion file. Remaining: $($pcs.Count) PCs" -ForegroundColor Yellow
    }
}

Write-Host "Computers to scan: $($pcs.Count)"
if ($pcs.Count -eq 0) {
    Write-Warning 'No computers found. Nothing to scan.'
    return [pscustomobject]@{ Status = 'Empty'; Message = 'No computers found.' }
}

# ================= 2) Hardware (CIM / DCOM) =================
if (-not $SkipHardware) {
    Write-Host '[STEP:2] Hardware Scan (WMI/CIM)...' -ForegroundColor Cyan
    Write-Host '--- Hardware scan ---'

    # Pre-load Master Database to track Fail_Count & preserve previous license/specs
    $masterDict = [ordered]@{}
    if (Test-Path -LiteralPath $MasterFile) {
        try {
            $oldMaster = Import-Csv -LiteralPath $MasterFile -Encoding UTF8
            foreach ($row in $oldMaster) {
                if ($row.PCName) {
                    $masterDict[$row.PCName.ToUpper()] = $row
                }
            }
        } catch {
            Write-Warning "Could not parse existing Master file: $($_.Exception.Message)"
        }
    }

    $i = 0
    $hw = foreach ($pc in $pcs) {
        $i++
        Write-Progress -Activity 'Hardware scan' -Status "$pc ($i/$($pcs.Count))" -PercentComplete (10 + [math]::Round(55 * $i / $pcs.Count))
        Write-Host "[STAGE:HW|$i|$($pcs.Count)] Scanning $pc ($i/$($pcs.Count))..."

        $key = $pc.ToUpper()
        $prevFailCount = 0
        $prevWinLicense = '-'
        $prevOfficeLicense = '-'
        $prevOfficeDetail = '-'
        $oldRecord = $null
        if ($masterDict.Contains($key)) {
            $mRow = $masterDict[$key]
            $oldRecord = $mRow
            if ($mRow.Fail_Count) { [int]::TryParse($mRow.Fail_Count, [ref]$prevFailCount) | Out-Null }
            if ($mRow.Win_License -and $mRow.Win_License -ne '-') { $prevWinLicense = $mRow.Win_License }
            if ($mRow.Office_License -and $mRow.Office_License -ne '-') { $prevOfficeLicense = $mRow.Office_License }
            if ($mRow.Office_Detail -and $mRow.Office_Detail -ne '-') { $prevOfficeDetail = $mRow.Office_Detail }
        }

        if (-not (Test-PCConnection $pc)) {
            $ad = Get-ADInfo $pc
            $newFail = $prevFailCount + 1
            $hData = @{
                PCName         = $pc
                Status         = 'Offline'
                Status_Detail  = 'Host unreachable (ICMP ping and WinRM/RPC ports timed out)'
                Fail_Count     = $newFail
                Win_License    = $prevWinLicense
                Office_License = $prevOfficeLicense
                Office_Detail  = $prevOfficeDetail
                AD_LastLogon   = $ad.AD_LastLogon
                AD_OU          = $ad.AD_OU
                Scan_Count     = if ($oldRecord -and $oldRecord.Scan_Count) { $oldRecord.Scan_Count } else { '0' }
                First_Seen     = if ($oldRecord -and $oldRecord.First_Seen -and $oldRecord.First_Seen -ne '-') { $oldRecord.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                Last_Scan      = if ($oldRecord -and $oldRecord.Last_Scan) { $oldRecord.Last_Scan } else { '-' }
            }
            if ($oldRecord -and ($oldRecord.Status -eq 'OK' -or ($oldRecord.CPU -and $oldRecord.CPU -ne '-'))) {
                $hData.Maker       = $oldRecord.Maker
                $hData.Model       = $oldRecord.Model
                $hData.Serial      = $oldRecord.Serial
                $hData.CPU         = $oldRecord.CPU
                $hData.Cores       = $oldRecord.Cores
                $hData.RAM_GB      = $oldRecord.RAM_GB
                $hData.Disk_C_Free = $oldRecord.Disk_C_Free
                $hData.Disks       = $oldRecord.Disks
                $hData.GPU         = $oldRecord.GPU
                $hData.OS          = $oldRecord.OS
                $hData.OSBuild     = $oldRecord.OSBuild
                $hData.IP          = $oldRecord.IP
                $hData.User        = $oldRecord.User
            }
            $itemOffline = New-HardwareRecord $hData
            Write-Host ('[LIVE_PC] ' + ($itemOffline | ConvertTo-Json -Compress))
            $itemOffline
            continue
        }
        try {
            $isLocal = ($pc -eq $env:COMPUTERNAME -or $pc -eq 'localhost' -or $pc -eq '127.0.0.1')
            $s = $null
            if ($isLocal) {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
                $disk = Get-CimInstance Win32_DiskDrive -ErrorAction Stop
                $gpu = Get-CimInstance Win32_VideoController -ErrorAction Stop
                $ram = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
                $net = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object IPEnabled
                $cDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
            } else {
                $opt = New-CimSessionOption -Protocol Dcom
                $s = New-CimSession -ComputerName $pc -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop
                $cs = Get-CimInstance Win32_ComputerSystem -CimSession $s
                $bios = Get-CimInstance Win32_BIOS -CimSession $s
                $os = Get-CimInstance Win32_OperatingSystem -CimSession $s
                $cpu = Get-CimInstance Win32_Processor -CimSession $s | Select-Object -First 1
                $disk = Get-CimInstance Win32_DiskDrive -CimSession $s
                $gpu = Get-CimInstance Win32_VideoController -CimSession $s
                $ram = Get-CimInstance Win32_PhysicalMemory -CimSession $s
                $net = Get-CimInstance Win32_NetworkAdapterConfiguration -CimSession $s | Where-Object IPEnabled
                $cDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -CimSession $s -ErrorAction SilentlyContinue
            }

            # Skip server if detected by OS ProductType (1=Workstation, 2=Domain Controller, 3=Server)
            if ($SkipServers -and -not $isLocal -and $os -and $os.ProductType -and $os.ProductType -ne 1) {
                Write-Host "  [SKIP SERVER] Skipping $pc (Detected Server OS: $($os.Caption))" -ForegroundColor Yellow
                if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue }
                continue
            }
            $lastBootStr = '-'
            $uptimeStr = '-'
            if ($os.LastBootUpTime) {
                try {
                    $bootDt = if ($os.LastBootUpTime -is [datetime]) { $os.LastBootUpTime } else { [datetime]$os.LastBootUpTime }
                    $lastBootStr = $bootDt.ToString('yyyy-MM-dd HH:mm')
                    $diff = (Get-Date) - $bootDt
                    if ($diff.TotalDays -ge 1) {
                        $uptimeStr = "$([math]::Floor($diff.TotalDays))d $([int]$diff.Hours)h"
                    } else {
                        $uptimeStr = "$([int]$diff.Hours)h $([int]$diff.Minutes)m"
                    }
                } catch {}
            }

            # Extended metrics: C: Free Space
            $cDiskSummary = '-'
            if ($cDrive -and $cDrive.Size -gt 0) {
                try {
                    $freeB = [double]$cDrive.FreeSpace
                    $totalB = [double]$cDrive.Size
                    $cFreeGB = [math]::Round($freeB / 1GB, 1)
                    $cTotalGB = [math]::Round($totalB / 1GB, 0)
                    $pct = [math]::Round(($freeB / $totalB) * 100, 0)
                    $cDiskSummary = "$cFreeGB / $cTotalGB GB ($pct% free)"
                } catch {}
            }

            $ad = Get-ADInfo $pc

            # Query Windows & Office License Channel & Activation Status
            $winLicenseStr = '-'
            $officeLicenseStr = '-'
            $officeDetailStr = '-'
            try {
                $slpItems = if ($isLocal) {
                    @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey is not null" -ErrorAction SilentlyContinue)
                } elseif ($s) {
                    @(Get-CimInstance SoftwareLicensingProduct -CimSession $s -Filter "PartialProductKey is not null" -OperationTimeoutSec 10 -ErrorAction SilentlyContinue)
                } else { @() }

                # 1. Windows License
                $winLic = $slpItems | Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } | Select-Object -First 1
                if ($winLic) {
                    $rawChan = if ($winLic.ProductKeyChannel) { $winLic.ProductKeyChannel } else { [string]$winLic.Description }
                    $chan = if ($rawChan -match '(?i)OEM') {
                        'OEM'
                    } elseif ($rawChan -match '(?i)VOLUME_KMS|Volume:GVLK|KMS') {
                        'Volume (KMS)'
                    } elseif ($rawChan -match '(?i)VOLUME_MAK|MAK') {
                        'Volume (MAK)'
                    } elseif ($rawChan -match '(?i)Volume') {
                        'Volume'
                    } elseif ($rawChan -match '(?i)RETAIL') {
                        'Retail'
                    } else {
                        'OEM/Retail'
                    }
                    $actStatus = if ($winLic.LicenseStatus -eq 1) { 'Activated' } elseif ($winLic.LicenseStatus -eq 0) { 'Unlicensed' } else { 'Grace' }
                    $winLicenseStr = "$chan ($actStatus)"
                } elseif ($prevWinLicense -ne '-') {
                    $winLicenseStr = $prevWinLicense
                }

                # 2. Office License
                $c2rProdIds = ''
                if ($isLocal) {
                    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
                    if ($c2r -and $c2r.ProductReleaseIds) { $c2rProdIds = [string]$c2r.ProductReleaseIds }
                } elseif ($s) {
                    try {
                        $c2rRes = Invoke-CimMethod -CimSession $s -Namespace 'root\default' -ClassName StdRegProv -MethodName GetStringValue -Arguments @{
                            hDefKey     = [uint32]2147483650 # HKLM
                            sSubKeyName = 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
                            sValueName  = 'ProductReleaseIds'
                        } -ErrorAction SilentlyContinue
                        if ($c2rRes -and $c2rRes.sValue) { $c2rProdIds = [string]$c2rRes.sValue }
                    } catch {}
                }

                $officeSlp = $slpItems | Where-Object { $_.Name -match 'Office|O16|O15|O14|0ff1ce15-a989-479d-af46-f275c6370663' }
                $offParsed = Parse-OfficeLicenseInfo $c2rProdIds $officeSlp
                $officeLicenseStr = $offParsed.Badge
                $officeDetailStr  = $offParsed.Detail
            } catch {}

            if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue }

            if ($officeLicenseStr -eq '-' -and $prevOfficeLicense -ne '-') {
                $officeLicenseStr = $prevOfficeLicense
                $officeDetailStr  = $prevOfficeDetail
            }

            $itemOk = New-HardwareRecord @{
                PCName         = $cs.Name
                Status         = 'OK'
                Status_Detail  = 'Hardware scan completed successfully'
                Fail_Count     = 0
                Win_License    = $winLicenseStr
                Office_License = $officeLicenseStr
                Office_Detail  = $officeDetailStr
                User           = $cs.UserName
                Maker          = $cs.Manufacturer
                Model          = $cs.Model
                Serial         = $bios.SerialNumber
                CPU            = $cpu.Name
                Cores          = $cpu.NumberOfCores
                RAM_GB         = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB)
                Disk_C_Free    = $cDiskSummary
                Disks          = ($disk | ForEach-Object { "$($_.Model) $([math]::Round($_.Size/1GB))GB" }) -join '; '
                GPU            = ($gpu.Name) -join '; '
                OS             = $os.Caption
                OSBuild        = $os.BuildNumber
                Last_Boot      = $lastBootStr
                Uptime         = $uptimeStr
                AD_LastLogon   = $ad.AD_LastLogon
                AD_OU          = $ad.AD_OU
                IP             = ($net.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '
                MAC            = ($net.MACAddress) -join ', '
                Scan_Count     = 1
                First_Seen     = Get-Date -Format 'yyyy-MM-dd HH:mm'
                Last_Scan      = Get-Date -Format 'yyyy-MM-dd HH:mm'
            }
            Write-Host ('[LIVE_PC] ' + ($itemOk | ConvertTo-Json -Compress))
            $itemOk
        }
        catch {
            if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue }
            $ad = Get-ADInfo $pc
            $newFail = $prevFailCount + 1
            $hDataErr = @{
                PCName         = $pc
                Status         = "Error"
                Status_Detail  = $_.Exception.Message
                Fail_Count     = $newFail
                Win_License    = $prevWinLicense
                Office_License = $prevOfficeLicense
                Office_Detail  = $prevOfficeDetail
                AD_LastLogon   = $ad.AD_LastLogon
                AD_OU          = $ad.AD_OU
                Scan_Count     = if ($oldRecord -and $oldRecord.Scan_Count) { $oldRecord.Scan_Count } else { '0' }
                First_Seen     = if ($oldRecord -and $oldRecord.First_Seen -and $oldRecord.First_Seen -ne '-') { $oldRecord.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                Last_Scan      = if ($oldRecord -and $oldRecord.Last_Scan) { $oldRecord.Last_Scan } else { '-' }
            }
            if ($oldRecord -and ($oldRecord.Status -eq 'OK' -or ($oldRecord.CPU -and $oldRecord.CPU -ne '-'))) {
                $hDataErr.Maker       = $oldRecord.Maker
                $hDataErr.Model       = $oldRecord.Model
                $hDataErr.Serial      = $oldRecord.Serial
                $hDataErr.CPU         = $oldRecord.CPU
                $hDataErr.Cores       = $oldRecord.Cores
                $hDataErr.RAM_GB      = $oldRecord.RAM_GB
                $hDataErr.Disk_C_Free = $oldRecord.Disk_C_Free
                $hDataErr.Disks       = $oldRecord.Disks
                $hDataErr.GPU         = $oldRecord.GPU
                $hDataErr.OS          = $oldRecord.OS
                $hDataErr.OSBuild     = $oldRecord.OSBuild
                $hDataErr.IP          = $oldRecord.IP
                $hDataErr.User        = $oldRecord.User
            }
            $itemErr = New-HardwareRecord $hDataErr
            Write-Host ('[LIVE_PC] ' + ($itemErr | ConvertTo-Json -Compress))
            $itemErr
        }
    }
    Write-Progress -Activity 'Hardware scan' -Completed

    # --- Master Database Synchronization ---
    if ($MasterMode) {
        foreach ($r in $hw) {
            $key = $r.PCName.ToUpper()
            if ($r.Status -eq 'OK') {
                if ($masterDict.Contains($key)) {
                    $old = $masterDict[$key]
                    $prevCount = 0
                    if ($old.Scan_Count) { [int]::TryParse($old.Scan_Count, [ref]$prevCount) | Out-Null }
                    $r.Scan_Count = [string]($prevCount + 1)
                    $r.First_Seen = if ($old.First_Seen -and $old.First_Seen -ne '-') { $old.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                    $r.Last_Scan  = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Fail_Count = 0
                } else {
                    $r.Scan_Count = '1'
                    $r.First_Seen = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Last_Scan  = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Fail_Count = 0
                }
                $masterDict[$key] = $r
            } else {
                # Host is Offline or Error
                if ($masterDict.Contains($key)) {
                    $old = $masterDict[$key]
                    $prevCount = if ($old.Scan_Count) { $old.Scan_Count } else { '0' }
                    $firstSeen = if ($old.First_Seen -and $old.First_Seen -ne '-') { $old.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                    $hMerged = @{
                        PCName         = $r.PCName
                        Status         = if ($old.Status -eq 'OK' -or ($old.CPU -and $old.CPU -ne '-')) { "Offline (Was OK)" } else { $r.Status }
                        Status_Detail  = $r.Status_Detail
                        Fail_Count     = $r.Fail_Count
                        Win_License    = if ($r.Win_License -and $r.Win_License -ne '-') { $r.Win_License } else { $old.Win_License }
                        Office_License = if ($r.Office_License -and $r.Office_License -ne '-') { $r.Office_License } else { $old.Office_License }
                        Office_Detail  = if ($r.Office_Detail -and $r.Office_Detail -ne '-') { $r.Office_Detail } else { $old.Office_Detail }
                        User           = if ($old.User -and $old.User -ne '-') { $old.User } else { '-' }
                        Maker          = if ($old.Maker -and $old.Maker -ne '-') { $old.Maker } else { '-' }
                        Model          = if ($old.Model -and $old.Model -ne '-') { $old.Model } else { '-' }
                        Serial         = if ($old.Serial -and $old.Serial -ne '-') { $old.Serial } else { '-' }
                        CPU            = if ($old.CPU -and $old.CPU -ne '-') { $old.CPU } else { '-' }
                        Cores          = if ($old.Cores -and $old.Cores -ne '-') { $old.Cores } else { '-' }
                        RAM_GB         = if ($old.RAM_GB -and $old.RAM_GB -ne '-') { $old.RAM_GB } else { '-' }
                        Disk_C_Free    = if ($old.Disk_C_Free -and $old.Disk_C_Free -ne '-') { $old.Disk_C_Free } else { '-' }
                        Disks          = if ($old.Disks -and $old.Disks -ne '-') { $old.Disks } else { '-' }
                        GPU            = if ($old.GPU -and $old.GPU -ne '-') { $old.GPU } else { '-' }
                        OS             = if ($old.OS -and $old.OS -ne '-') { $old.OS } else { '-' }
                        OSBuild        = if ($old.OSBuild -and $old.OSBuild -ne '-') { $old.OSBuild } else { '-' }
                        Last_Boot      = if ($old.Last_Boot -and $old.Last_Boot -ne '-') { $old.Last_Boot } else { '-' }
                        Uptime         = if ($old.Uptime -and $old.Uptime -ne '-') { $old.Uptime } else { '-' }
                        AD_LastLogon   = if ($r.AD_LastLogon -and $r.AD_LastLogon -ne '-') { $r.AD_LastLogon } else { $old.AD_LastLogon }
                        AD_OU          = if ($r.AD_OU -and $r.AD_OU -ne '-') { $r.AD_OU } else { $old.AD_OU }
                        IP             = if ($old.IP -and $old.IP -ne '-') { $old.IP } else { '-' }
                        MAC            = if ($old.MAC -and $old.MAC -ne '-') { $old.MAC } else { '-' }
                        Scan_Count     = $prevCount
                        First_Seen     = $firstSeen
                        Last_Scan      = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    }
                    $masterDict[$key] = New-HardwareRecord $hMerged
                } else {
                    $masterDict[$key] = $r
                }
            }
        }

        # Save Master CSV with standardized columns
        $masterRows = @($masterDict.Values | Sort-Object PCName)
        $masterRows | Export-Csv $MasterFile -NoTypeInformation -Encoding UTF8
        Write-Host "Master Database updated: $($masterRows.Count) total records -> $MasterFile" -ForegroundColor Cyan
    }

    # Snapshot CSV for this specific run
    $fHw = Join-Path $OutDir "Hardware_$stamp.csv"
    $hw | Export-Csv $fHw -NoTypeInformation -Encoding UTF8
    $hwOk = @($hw | Where-Object { $_.Status -eq 'OK' }).Count
    Write-Host "Hardware done. OK: $hwOk / $($pcs.Count) -> $fHw"
}

# ================= 3) Installed software (optional) =================
if ($Software) {
    Write-Host '[STEP:3] Software Scan (WinRM/DCOM)...' -ForegroundColor Cyan
    Write-Progress -Activity 'Software scan' -Status 'Starting software scan...' -PercentComplete 68
    Write-Host '--- Software scan ---'

    # --- Method A: WinRM (fast, parallel) ---
    $remoteBlock = {
        param([bool]$IncludeUser, [bool]$IncludeHidden)

        $paths = @(
            @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             Arch = '64-bit'; Scope = 'Machine' },
            @{ P = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = '32-bit'; Scope = 'Machine' }
        )
        if ($IncludeUser) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
            Get-ChildItem HKU:\ -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
                ForEach-Object {
                    $paths += @{ P = "HKU:\$($_.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = 'User'; Scope = "User:$($_.PSChildName)" }
                }
        }

        foreach ($x in $paths) {
            if (-not (Test-Path $x.P)) { continue }
            foreach ($key in Get-ChildItem $x.P -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
                if (-not $p.DisplayName) { continue }
                if (-not $IncludeHidden) {
                    if ($p.SystemComponent -eq 1) { continue }
                    if ($p.ParentKeyName) { continue }
                    if ($p.ReleaseType -in 'Update', 'Security Update', 'Hotfix', 'Update Rollup', 'Service Pack') { continue }
                }
                [pscustomobject]@{
                    Name            = $p.DisplayName
                    Version         = $p.DisplayVersion
                    Publisher       = $p.Publisher
                    InstallDate     = $p.InstallDate
                    InstallLocation = $p.InstallLocation
                    SizeMB          = if ($p.EstimatedSize) { [math]::Round($p.EstimatedSize / 1024, 1) } else { $null }
                    Arch            = $x.Arch
                    Scope           = $x.Scope
                    RegistryKey     = $key.PSChildName
                }
            }
        }
    }

    $rows = @()
    if ($ScanLocalhost) {
        Write-Host 'Local scan: reading software from registry directly ...'
        $localResult = & $remoteBlock -IncludeUser $IncludeUserInstalls.IsPresent -IncludeHidden $IncludeHidden.IsPresent
        $rows = @($localResult | ForEach-Object {
            $_ | Add-Member -MemberType NoteProperty -Name 'PSComputerName' -Value $env:COMPUTERNAME -PassThru
        })
    } else {
        Write-Host 'Method A: WinRM ...'
        Write-Progress -Activity 'Software scan' -Status 'Scanning via WinRM (parallel)...' -PercentComplete 75
        $winrmErr = @()
        $rows = @(Invoke-Command -ComputerName $pcs -ScriptBlock $remoteBlock `
                -ArgumentList $IncludeUserInstalls.IsPresent, $IncludeHidden.IsPresent `
                -ThrottleLimit $Throttle -ErrorAction SilentlyContinue -ErrorVariable winrmErr)
    }

    $all = New-Object System.Collections.Generic.List[object]
    $status = New-Object System.Collections.Generic.List[object]

    foreach ($g in ($rows | Group-Object PSComputerName)) {
        foreach ($r in $g.Group) {
            $all.Add([pscustomobject]@{
                    PCName = $g.Name; Name = $r.Name; Version = $r.Version; Publisher = $r.Publisher
                    InstallDate = $r.InstallDate; InstallLocation = $r.InstallLocation; SizeMB = $r.SizeMB
                    Arch = $r.Arch; Scope = $r.Scope; RegistryKey = $r.RegistryKey
                })
        }
        $status.Add([pscustomobject]@{ PCName = $g.Name; Status = 'OK-WinRM'; Count = $g.Count })
    }

    $okSet = @($rows | ForEach-Object { $_.PSComputerName } | Select-Object -Unique)
    if ($okSet.Count -gt 0) {
        Write-Host "[STAGE:SW|$($okSet.Count)|$($pcs.Count)] WinRM software scan completed for $($okSet.Count) PCs..."
    }
    $failed = @($pcs | Where-Object { $_ -notin $okSet })

    # --- Method B: DCOM fallback (StdRegProv) for PCs without WinRM ---
    function Get-SoftwareDcom {
        param([string]$pc, [bool]$IncludeUser, [bool]$IncludeHidden)

        $sess = New-CimSession -ComputerName $pc -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 15 -ErrorAction Stop
        try {
            function Reg([string]$m, [hashtable]$a) {
                Invoke-CimMethod -CimSession $sess -Namespace 'root\default' -ClassName StdRegProv -MethodName $m -Arguments $a -ErrorAction Stop
            }
            function GetS($h, $sub, $n) { (Reg 'GetStringValue' @{ hDefKey = $h; sSubKeyName = $sub; sValueName = $n }).sValue }
            function GetD($h, $sub, $n) { (Reg 'GetDWORDValue'  @{ hDefKey = $h; sSubKeyName = $sub; sValueName = $n }).uValue }

            $HKLM = [uint32]2147483650
            $HKU = [uint32]2147483651
            $targets = @(
                @{ H = $HKLM; P = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             Arch = '64-bit'; Scope = 'Machine' },
                @{ H = $HKLM; P = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = '32-bit'; Scope = 'Machine' }
            )
            if ($IncludeUser) {
                $sids = (Reg 'EnumKey' @{ hDefKey = $HKU; sSubKeyName = '' }).sNames | Where-Object { $_ -match '^S-1-5-21-[\d-]+$' }
                foreach ($sid in $sids) {
                    $targets += @{ H = $HKU; P = "$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = 'User'; Scope = "User:$sid" }
                }
            }

            foreach ($t in $targets) {
                $keys = (Reg 'EnumKey' @{ hDefKey = $t.H; sSubKeyName = $t.P }).sNames
                foreach ($k in $keys) {
                    $sub = "$($t.P)\$k"
                    $name = GetS $t.H $sub 'DisplayName'
                    if (-not $name) { continue }
                    if (-not $IncludeHidden) {
                        if ((GetD $t.H $sub 'SystemComponent') -eq 1) { continue }
                        if (GetS $t.H $sub 'ParentKeyName') { continue }
                        if ((GetS $t.H $sub 'ReleaseType') -in 'Update', 'Security Update', 'Hotfix', 'Update Rollup', 'Service Pack') { continue }
                    }
                    $size = GetD $t.H $sub 'EstimatedSize'
                    [pscustomobject]@{
                        PCName = $pc; Name = $name
                        Version = GetS $t.H $sub 'DisplayVersion'
                        Publisher = GetS $t.H $sub 'Publisher'
                        InstallDate = GetS $t.H $sub 'InstallDate'
                        InstallLocation = GetS $t.H $sub 'InstallLocation'
                        SizeMB = if ($size) { [math]::Round($size / 1024, 1) } else { $null }
                        Arch = $t.Arch; Scope = $t.Scope; RegistryKey = $k
                    }
                }
            }
        }
        finally { Remove-CimSession $sess -ErrorAction SilentlyContinue }
    }

    if ($failed.Count -gt 0) {
        Write-Host "Method B: DCOM fallback for $($failed.Count) PCs (slower, one by one) ..."
        $i = 0
        foreach ($pc in $failed) {
            $i++
            $swDoneCount = $okSet.Count + $i
            Write-Progress -Activity 'Software: DCOM fallback' -Status "$pc ($i/$($failed.Count))" -PercentComplete (75 + [math]::Round(12 * $i / $failed.Count))
            Write-Host "[STAGE:SW|$swDoneCount|$($pcs.Count)] Scanning software on $pc ($swDoneCount/$($pcs.Count))..."
            if ($pc -eq $env:COMPUTERNAME -or $pc -eq 'localhost' -or $pc -eq '127.0.0.1') {
                try {
                    $localRows = & $remoteBlock -IncludeUser $IncludeUserInstalls.IsPresent -IncludeHidden $IncludeHidden.IsPresent
                    foreach ($r in $localRows) {
                        $all.Add([pscustomobject]@{
                            PCName = $pc; Name = $r.Name; Version = $r.Version; Publisher = $r.Publisher
                            InstallDate = $r.InstallDate; InstallLocation = $r.InstallLocation; SizeMB = $r.SizeMB
                            Arch = $r.Arch; Scope = $r.Scope; RegistryKey = $r.RegistryKey
                        })
                    }
                    $status.Add([pscustomobject]@{ PCName = $pc; Status = 'OK-Local'; Count = $localRows.Count })
                    continue
                } catch { }
            }
            if (-not (Test-PCConnection $pc)) {
                $status.Add([pscustomobject]@{ PCName = $pc; Status = 'Offline'; Count = 0 })
                continue
            }
            try {
                $res = @(Get-SoftwareDcom -pc $pc -IncludeUser $IncludeUserInstalls.IsPresent -IncludeHidden $IncludeHidden.IsPresent)
                foreach ($r in $res) { $all.Add($r) }
                $status.Add([pscustomobject]@{ PCName = $pc; Status = 'OK-DCOM'; Count = $res.Count })
            }
            catch {
                $status.Add([pscustomobject]@{ PCName = $pc; Status = "Error: $($_.Exception.Message)"; Count = 0 })
            }
        }
        Write-Progress -Activity 'Software: DCOM fallback' -Completed
    }

    # --- Clean + export ---
    foreach ($r in $all) {
        if ($r.InstallDate -match '^\d{8}$') {
            try { $r.InstallDate = [datetime]::ParseExact($r.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { }
        }
    }
    $final = $all | Where-Object { $_.Name -like $NameFilter } | Sort-Object PCName, Name

    $fSoft = Join-Path $OutDir "Software_$stamp.csv"
    $fSum = Join-Path $OutDir "Software_Summary_$stamp.csv"
    $fStat = Join-Path $OutDir "Software_ScanStatus_$stamp.csv"

    $final | Export-Csv $fSoft -NoTypeInformation -Encoding UTF8

    # Per-PC output: one CSV per computer (folder) + one summary row per computer
    $fByPC = Join-Path $OutDir "Software_ByPC_$stamp.html"
    $fSumPC = Join-Path $OutDir "Software_PerPC_$stamp.csv"
    $perPc = foreach ($g in ($final | Group-Object PCName)) {
        $keyApps = @($g.Group | Where-Object { $_.Name -match 'Office|Microsoft 365|Google Chrome|Firefox|Adobe|7-Zip|CrowdStrike|Antivirus|Defender|AnyDesk|TeamViewer' } | Select-Object -ExpandProperty Name -First 4)
        $topApps = if ($keyApps.Count -gt 0) { $keyApps -join ', ' } else { (($g.Group | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ') }
        $methodUsed = @($status | Where-Object { $_.PCName -ieq $g.Name } | Select-Object -ExpandProperty Status -First 1)
        if (-not $methodUsed) { $methodUsed = 'OK' }

        $liveSwObj = [pscustomobject]@{
            PCName        = $g.Name
            Status        = 'OK'
            Method        = $methodUsed
            SoftwareCount = $g.Count
            KeySoftware   = $topApps
            SoftwareList  = (($g.Group | ForEach-Object { if ($_.Version) { "$($_.Name) $($_.Version)" } else { $_.Name } }) -join '; ')
        }
        Write-Host ('[LIVE_SW] ' + ($liveSwObj | ConvertTo-Json -Compress))
        $liveSwObj
    }
    # Also emit failed/offline hosts in [LIVE_SW]
    foreach ($st in $status) {
        if ($st.Status -ne 'OK-WinRM' -and $st.Status -ne 'OK-DCOM' -and $st.Status -ne 'OK-Local') {
            $swErrObj = [pscustomobject]@{
                PCName        = $st.PCName
                Status        = if ($st.Status -match 'Offline') { 'Offline' } else { 'Error' }
                Method        = '-'
                SoftwareCount = 0
                KeySoftware   = '-'
                SoftwareList  = $st.Status
            }
            Write-Host ('[LIVE_SW] ' + ($swErrObj | ConvertTo-Json -Compress))
        }
    }
    $perPc | Export-Csv $fSumPC -NoTypeInformation -Encoding UTF8

    # Single combined file grouped by PC (open in a browser; searchable, expand/collapse per PC)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Software by PC</title>')
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Tahoma,sans-serif;margin:20px}details{margin:6px 0;border:1px solid #ccc;border-radius:6px}summary{cursor:pointer;padding:8px;font-weight:bold;background:#f2f2f2}table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-top:1px solid #ddd;padding:4px 8px;text-align:left}th{background:#fafafa}#q{padding:6px;width:320px}</style></head><body>')
    [void]$sb.AppendLine("<h2>Software by PC ($stamp)</h2>")
    [void]$sb.AppendLine('<p><input id="q" placeholder="Search software or PC name..." oninput="f()"> <button onclick="t(true)">Expand all</button> <button onclick="t(false)">Collapse all</button></p>')
    foreach ($g in ($final | Group-Object PCName)) {
        [void]$sb.AppendLine("<details><summary>$(& $enc $g.Name) - $($g.Count) items</summary><table><tr><th>Name</th><th>Version</th><th>Publisher</th><th>InstallDate</th><th>InstallLocation</th><th>Arch</th><th>Scope</th></tr>")
        foreach ($r in $g.Group) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $r.Name)</td><td>$(& $enc $r.Version)</td><td>$(& $enc $r.Publisher)</td><td>$(& $enc $r.InstallDate)</td><td>$(& $enc $r.InstallLocation)</td><td>$(& $enc $r.Arch)</td><td>$(& $enc $r.Scope)</td></tr>")
        }
        [void]$sb.AppendLine('</table></details>')
    }
    [void]$sb.AppendLine(@'
<script>
function f(){var q=document.getElementById('q').value.toLowerCase();
document.querySelectorAll('details').forEach(function(d){
var nm=d.querySelector('summary').textContent.toLowerCase().indexOf(q)>-1,any=false;
d.querySelectorAll('tr').forEach(function(r,i){if(i==0)return;
var m=!q||nm||r.textContent.toLowerCase().indexOf(q)>-1;r.style.display=m?'':'none';if(m)any=true;});
d.style.display=(!q||nm||any)?'':'none';d.open=!!q&&any;});}
function t(o){document.querySelectorAll('details').forEach(function(d){d.open=o;});}
</script></body></html>
'@)
    Set-Content -Path $fByPC -Value $sb.ToString() -Encoding UTF8

    $final | Group-Object Name, Version | ForEach-Object {
        $f = $_.Group[0]
        [pscustomobject]@{
            Name      = $f.Name
            Version   = $f.Version
            Publisher = $f.Publisher
            PCCount   = ($_.Group | Select-Object -ExpandProperty PCName -Unique).Count
        }
    } | Sort-Object Name, Version | Export-Csv $fSum -NoTypeInformation -Encoding UTF8

    $status | Sort-Object PCName | Export-Csv $fStat -NoTypeInformation -Encoding UTF8

    # --- Software Master Database Synchronization ---
    $fSoftMaster = $SoftwareMasterFile
    $fSumMaster  = Join-Path $OutDir 'Software_Summary_Master.csv'
    if ($MasterMode) {
        $masterSwDict = [ordered]@{} # Key: PCName.ToUpper() -> List of software records
        
        # 1. Load existing Software Master if present
        if (Test-Path -LiteralPath $fSoftMaster) {
            try {
                $oldSwRows = Import-Csv -LiteralPath $fSoftMaster -Encoding UTF8
                foreach ($row in $oldSwRows) {
                    if ($row.PCName) {
                        $key = $row.PCName.ToUpper()
                        if (-not $masterSwDict.Contains($key)) {
                            $masterSwDict[$key] = [System.Collections.Generic.List[object]]::new()
                        }
                        $masterSwDict[$key].Add($row)
                    }
                }
            } catch {
                Write-Warning "Could not parse existing Software Master file: $($_.Exception.Message)"
            }
        }

        # 2. For each successfully scanned PC in this run (OK*), update its software list in Master
        $scannedOkPCs = @($status | Where-Object { $_.Status -like 'OK*' } | Select-Object -ExpandProperty PCName -Unique)
        $newSwGroups = $final | Group-Object PCName

        foreach ($okPC in $scannedOkPCs) {
            $key = $okPC.ToUpper()
            $matchingGroup = $newSwGroups | Where-Object { $_.Name -eq $okPC } | Select-Object -First 1
            $swList = [System.Collections.Generic.List[object]]::new()
            if ($matchingGroup) {
                foreach ($item in $matchingGroup.Group) {
                    $swList.Add($item)
                }
            }
            $masterSwDict[$key] = $swList
        }

        # 3. Export combined Software_Master.csv
        $allMasterSw = [System.Collections.Generic.List[object]]::new()
        foreach ($key in ($masterSwDict.Keys | Sort-Object)) {
            foreach ($swItem in $masterSwDict[$key]) {
                $allMasterSw.Add($swItem)
            }
        }

        $allMasterSw | Export-Csv -LiteralPath $fSoftMaster -NoTypeInformation -Encoding UTF8
        Write-Host "Software Master updated: $($allMasterSw.Count) total records across $($masterSwDict.Count) PCs -> $fSoftMaster" -ForegroundColor Cyan

        # 4. Export cumulative Software_Summary_Master.csv across entire organization
        if ($allMasterSw.Count -gt 0) {
            $allMasterSw | Group-Object Name, Version | ForEach-Object {
                $f = $_.Group[0]
                [pscustomobject]@{
                    Name      = $f.Name
                    Version   = $f.Version
                    Publisher = $f.Publisher
                    PCCount   = ($_.Group | Select-Object -ExpandProperty PCName -Unique).Count
                }
            } | Sort-Object Name, Version | Export-Csv -LiteralPath $fSumMaster -NoTypeInformation -Encoding UTF8
        }
    }

    $swOk = @($status | Where-Object { $_.Status -like 'OK*' }).Count
    Write-Host "Software done. OK: $swOk / $($pcs.Count)"
    Write-Host "  Detail  : $fSoft"
    if ($MasterMode) {
        Write-Host "  Master  : $fSoftMaster"
        Write-Host "  SumMstr : $fSumMaster"
    }
    Write-Host "  Summary : $fSum"
    Write-Host "  By PC   : $fByPC  (one file, grouped by computer)"
    Write-Host "  Per PC  : $fSumPC  (one row per computer)"
    Write-Host "  Status  : $fStat"
}
else {
    Write-Host '[STEP:3] Skipped Software Scan by User Setting' -ForegroundColor Gray
}

# ================= 4) Master DB Sync & Final Reports =================
Write-Host '[STEP:4] Synchronizing Master DB and Generating Reports...' -ForegroundColor Cyan
Write-Progress -Activity 'Report Generation' -Status 'Finalizing reports and Master DB...' -PercentComplete 95

Write-Progress -Activity 'Scan Complete' -Status 'All done' -PercentComplete 100
Write-Host '[STEP:5] Scan and Report Generation Completed (100%)' -ForegroundColor Green
Write-Host ''
Write-Host "All done -> $OutDir"

return [pscustomobject]@{
    Status            = 'Success'
    OutDir            = $OutDir
    HardwareCsv       = if (-not $SkipHardware) { $fHw } else { $null }
    MasterCsv         = if ($MasterMode -and -not $SkipHardware) { $MasterFile } else { $null }
    SoftwareHtml      = if ($Software) { $fByPC } else { $null }
    SoftwareCsv       = if ($Software) { $fSoft } else { $null }
    SoftwareMasterCsv = if ($MasterMode -and $Software) { $fSoftMaster } else { $null }
    Timestamp         = $stamp
}

