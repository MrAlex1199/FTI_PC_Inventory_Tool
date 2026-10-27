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
    [string]$MasterFile              # Custom path to Master CSV (defaults to OutDir\Hardware_Master.csv)
)

$Software = -not $NoSoftware

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

if (-not $MasterFile) {
    $MasterFile = Join-Path $OutDir 'Hardware_Master.csv'
}

$fHw = $null
$fByPC = $null
$fSoft = $null

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
        foreach ($res in $adResults) {
            $cName = [string]$res.Properties['name'][0]
            if ($cName) {
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
                        $dn = [string]$res.Properties['distinguishedname'][0]
                        $ous = [regex]::Matches($dn, 'OU=([^,]+)') | ForEach-Object { $_.Groups[1].Value }
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
            }
        }
        $pcs = $adResults | ForEach-Object { [string]$_.Properties['name'][0] } | Sort-Object
    } catch {
        Write-Warning "Active Directory query error: $($_.Exception.Message)"
        return [pscustomobject]@{ Status = 'Error'; Message = "Active Directory query error: $($_.Exception.Message)" }
    }
}

Write-Host "Computers to scan: $($pcs.Count)"
if ($pcs.Count -eq 0) {
    Write-Warning 'No computers found. Nothing to scan.'
    return [pscustomobject]@{ Status = 'Empty'; Message = 'No computers found.' }
}

# ================= 2) Hardware (CIM / DCOM) =================
if (-not $SkipHardware) {
    Write-Host '--- Hardware scan ---'
    $i = 0
    $hw = foreach ($pc in $pcs) {
        $i++
        Write-Progress -Activity 'Hardware scan' -Status "$pc ($i/$($pcs.Count))" -PercentComplete (100 * $i / $pcs.Count)

        if (-not (Test-PCConnection $pc)) {
            $ad = Get-ADInfo $pc
            [pscustomobject]@{
                PCName       = $pc
                Status       = 'Offline'
                User         = '-'
                Maker        = '-'
                Model        = '-'
                Serial       = '-'
                CPU          = '-'
                Cores        = '-'
                RAM_GB       = '-'
                Disk_C_Free  = '-'
                Disks        = '-'
                GPU          = '-'
                OS           = '-'
                OSBuild      = '-'
                Last_Boot    = '-'
                Uptime       = '-'
                AD_LastLogon = $ad.AD_LastLogon
                AD_OU        = $ad.AD_OU
                IP           = '-'
                MAC          = '-'
                Scan_Count   = 0
                First_Seen   = Get-Date -Format 'yyyy-MM-dd HH:mm'
                Last_Scan    = '-'
            }
            continue
        }
        try {
            $isLocal = ($pc -eq $env:COMPUTERNAME -or $pc -eq 'localhost' -or $pc -eq '127.0.0.1')
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
                $s = New-CimSession -ComputerName $pc -SessionOption $opt -ErrorAction Stop
                $cs = Get-CimInstance Win32_ComputerSystem -CimSession $s
                $bios = Get-CimInstance Win32_BIOS -CimSession $s
                $os = Get-CimInstance Win32_OperatingSystem -CimSession $s
                $cpu = Get-CimInstance Win32_Processor -CimSession $s | Select-Object -First 1
                $disk = Get-CimInstance Win32_DiskDrive -CimSession $s
                $gpu = Get-CimInstance Win32_VideoController -CimSession $s
                $ram = Get-CimInstance Win32_PhysicalMemory -CimSession $s
                $net = Get-CimInstance Win32_NetworkAdapterConfiguration -CimSession $s | Where-Object IPEnabled
                $cDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -CimSession $s -ErrorAction SilentlyContinue
                Remove-CimSession $s
            }

            # Extended metrics: LastBoot / Uptime
            $lastBootStr = '-'
            $uptimeStr = '-'
            if ($os.LastBootUpTime) {
                try {
                    $bootDt = if ($os.LastBootUpTime -is [datetime]) { $os.LastBootUpTime } else { [datetime]$os.LastBootUpTime }
                    $lastBootStr = $bootDt.ToString('yyyy-MM-dd HH:mm')
                    $diff = (Get-Date) - $bootDt
                    if ($diff.TotalDays -ge 1) {
                        $uptimeStr = "$([math]::Floor($diff.TotalDays)) วัน $([int]$diff.Hours) ชม."
                    } else {
                        $uptimeStr = "$([int]$diff.Hours) ชม. $([int]$diff.Minutes) นาที"
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

            [pscustomobject]@{
                PCName       = $cs.Name
                Status       = 'OK'
                User         = $cs.UserName
                Maker        = $cs.Manufacturer
                Model        = $cs.Model
                Serial       = $bios.SerialNumber
                CPU          = $cpu.Name
                Cores        = $cpu.NumberOfCores
                RAM_GB       = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB)
                Disk_C_Free  = $cDiskSummary
                Disks        = ($disk | ForEach-Object { "$($_.Model) $([math]::Round($_.Size/1GB))GB" }) -join '; '
                GPU          = ($gpu.Name) -join '; '
                OS           = $os.Caption
                OSBuild      = $os.BuildNumber
                Last_Boot    = $lastBootStr
                Uptime       = $uptimeStr
                AD_LastLogon = $ad.AD_LastLogon
                AD_OU        = $ad.AD_OU
                IP           = ($net.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '
                MAC          = ($net.MACAddress) -join ', '
                Scan_Count   = 1
                First_Seen   = Get-Date -Format 'yyyy-MM-dd HH:mm'
                Last_Scan    = Get-Date -Format 'yyyy-MM-dd HH:mm'
            }
        }
        catch {
            $ad = Get-ADInfo $pc
            [pscustomobject]@{
                PCName       = $pc
                Status       = "Error: $($_.Exception.Message)"
                User         = '-'
                Maker        = '-'
                Model        = '-'
                Serial       = '-'
                CPU          = '-'
                Cores        = '-'
                RAM_GB       = '-'
                Disk_C_Free  = '-'
                Disks        = '-'
                GPU          = '-'
                OS           = '-'
                OSBuild      = '-'
                Last_Boot    = '-'
                Uptime       = '-'
                AD_LastLogon = $ad.AD_LastLogon
                AD_OU        = $ad.AD_OU
                IP           = '-'
                MAC          = '-'
                Scan_Count   = 0
                First_Seen   = Get-Date -Format 'yyyy-MM-dd HH:mm'
                Last_Scan    = '-'
            }
        }
    }
    Write-Progress -Activity 'Hardware scan' -Completed

    # --- Master Database Synchronization ---
    if ($MasterMode) {
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

        # Merge newly scanned records
        foreach ($r in $hw) {
            $key = $r.PCName.ToUpper()
            if ($r.Status -eq 'OK') {
                if ($masterDict.Contains($key)) {
                    $old = $masterDict[$key]
                    $prevCount = 0
                    if ($old.Scan_Count) { [int]::TryParse($old.Scan_Count, [ref]$prevCount) | Out-Null }
                    $r.Scan_Count = $prevCount + 1
                    $r.First_Seen = if ($old.First_Seen -and $old.First_Seen -ne '-') { $old.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                    $r.Last_Scan  = Get-Date -Format 'yyyy-MM-dd HH:mm'
                } else {
                    $r.Scan_Count = 1
                    $r.First_Seen = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Last_Scan  = Get-Date -Format 'yyyy-MM-dd HH:mm'
                }
                $masterDict[$key] = $r
            } else {
                # Machine is Offline or Error
                if ($masterDict.Contains($key)) {
                    $old = $masterDict[$key]
                    # If the machine previously had specs from OK scan, preserve previous hardware details!
                    if ($old.Status -eq 'OK' -or ($old.CPU -and $old.CPU -ne '-')) {
                        $old.Status = "Offline (Was OK)"
                        $old.Last_Scan = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    } else {
                        $old.Status = $r.Status
                        $old.Last_Scan = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    }
                } else {
                    $masterDict[$key] = $r
                }
            }
        }

        # Save Master CSV
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
    $failed = @($pcs | Where-Object { $_ -notin $okSet })

    # --- Method B: DCOM fallback (StdRegProv) for PCs without WinRM ---
    function Get-SoftwareDcom {
        param([string]$pc, [bool]$IncludeUser, [bool]$IncludeHidden)

        $sess = New-CimSession -ComputerName $pc -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
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
            Write-Progress -Activity 'Software: DCOM fallback' -Status "$pc ($i/$($failed.Count))" -PercentComplete (100 * $i / $failed.Count)
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
        [pscustomobject]@{
            PCName        = $g.Name
            SoftwareCount = $g.Count
            SoftwareList  = (($g.Group | ForEach-Object { if ($_.Version) { "$($_.Name) $($_.Version)" } else { $_.Name } }) -join '; ')
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

    $swOk = @($status | Where-Object { $_.Status -like 'OK*' }).Count
    Write-Host "Software done. OK: $swOk / $($pcs.Count)"
    Write-Host "  Detail  : $fSoft"
    Write-Host "  Summary : $fSum"
    Write-Host "  By PC   : $fByPC  (one file, grouped by computer)"
    Write-Host "  Per PC  : $fSumPC  (one row per computer)"
    Write-Host "  Status  : $fStat"
}

Write-Host ''
Write-Host "All done -> $OutDir"

return [pscustomobject]@{
    Status       = 'Success'
    OutDir       = $OutDir
    HardwareCsv  = if (-not $SkipHardware) { $fHw } else { $null }
    MasterCsv    = if ($MasterMode -and -not $SkipHardware) { $MasterFile } else { $null }
    SoftwareHtml = if ($Software) { $fByPC } else { $null }
    SoftwareCsv  = if ($Software) { $fSoft } else { $null }
    Timestamp    = $stamp
}

