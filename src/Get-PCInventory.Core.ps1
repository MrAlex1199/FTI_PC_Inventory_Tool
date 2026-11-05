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
    [string]$ExcludeServerFile,      # Optional .txt file with hostnames/IPs to exclude from scan
    [string]$PingMethod = 'combined', # Reachability method: combined, icmp, tcp, udptcp, arp
    [string]$ProbePorts = '135,445,5985,5986,3389,139,80,443,5900', # Target ports for TCP/UDP probing
    [int]$PingTimeoutMs = 1000,      # Probe timeout in milliseconds
    [int]$PingProbes = 2,            # Number of ping probes/packets to send
    [int]$ThreadDelayMs = 20,        # Inter-host delay between starting threads in ms
    [switch]$ScanDeadHosts,          # Bypass reachability check and attempt scan on dead hosts
    [switch]$SkipBroadcast = $true,  # Skip *.0 and *.255 unassigned/broadcast addresses
    [bool]$AutoHealDns = $true       # Auto trigger ipconfig /registerdns on rescued ghost DNS hosts
)

$Software = -not $NoSoftware

# Parse and sanitize probe ports list (e.g. 135, 445, 5985, 3389)
$script:ParsedProbePorts = @(
    if ($ProbePorts) {
        $ProbePorts -split '[,;\s]+' | ForEach-Object {
            $p = 0
            if ([int]::TryParse($_.Trim(), [ref]$p) -and $p -ge 1 -and $p -le 65535) { $p }
        } | Select-Object -Unique
    }
)
if (-not $script:ParsedProbePorts -or $script:ParsedProbePorts.Count -eq 0) {
    $script:ParsedProbePorts = @(135, 445, 5985, 5986, 3389, 139, 80, 443, 5900)
}

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
function New-HardwareRecord($h) {
    if ($null -eq $h) {
        $h = @{}
    } elseif ($h -isnot [System.Collections.IDictionary]) {
        $tmp = @{}
        foreach ($prop in $h.PSObject.Properties) {
            $tmp[$prop.Name] = $prop.Value
        }
        $h = $tmp
    }
    return [pscustomobject][ordered]@{
        PCName         = if ($h.ContainsKey('PCName') -and $h.PCName) { [string]$h.PCName } else { '-' }
        Status         = if ($h.ContainsKey('Status') -and $h.Status) { [string]$h.Status } else { 'OK' }
        Method         = if ($h.ContainsKey('Method') -and $h.Method) { [string]$h.Method } else { '-' }
        Status_Detail  = if ($h.ContainsKey('Status_Detail') -and $h.Status_Detail) { [string]$h.Status_Detail } else { '' }
        Fail_Count     = if ($h.ContainsKey('Fail_Count') -and $null -ne $h.Fail_Count -and "$($h.Fail_Count)" -ne '') { [int]$h.Fail_Count } else { 0 }
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
        # Prioritize Activated (1), then Grace (5, 2), then others, with newer editions evaluated first
        $sortedSlp = @($slpList | Sort-Object @{
            Expression = { if ($_.LicenseStatus -eq 1) { 0 } elseif ($_.LicenseStatus -in 2, 5) { 1 } else { 2 } }
        }, @{
            Expression = {
                $nm = [string]$_.Name
                if ($nm -match '(?i)2024|Office24') { 0 }
                elseif ($nm -match '(?i)2021|Office21') { 1 }
                elseif ($nm -match '(?i)2019|Office19') { 2 }
                elseif ($nm -match '(?i)2016|Office16') { 3 }
                else { 4 }
            }
        })

        foreach ($p in $sortedSlp) {
            $name = [string]$p.Name
            $chan = [string]$p.ProductKeyChannel
            $desc = [string]$p.Description
            $stat = [int]$p.LicenseStatus # 1=Licensed, 5/2=Grace, 0=Unlicensed

            # Evaluate newest versions first to avoid "Office 16, Office21..." being falsely classified as 2016
            $edition = if ($name -match '(?i)Office24|Office\s*24|2024') {
                if ($name -match '(?i)HomeBusiness|Home_Business') { "Office 2024 H&B" }
                elseif ($name -match '(?i)HomeStudent|Home_Student') { "Office 2024 Home & Student" }
                elseif ($name -match '(?i)ProPlus|Professional') { "Office 2024 Pro" }
                else { "Office 2024" }
            } elseif ($name -match '(?i)Office21|Office\s*21|2021') {
                if ($name -match '(?i)HomeBusiness|Home_Business') { "Office 2021 H&B" }
                elseif ($name -match '(?i)HomeStudent|Home_Student') { "Office 2021 Home & Student" }
                elseif ($name -match '(?i)ProPlus|Professional') { "Office 2021 Pro" }
                else { "Office 2021" }
            } elseif ($name -match '(?i)Office19|Office\s*19|2019') {
                if ($name -match '(?i)HomeBusiness|Home_Business') { "Office 2019 H&B" }
                elseif ($name -match '(?i)HomeStudent|Home_Student') { "Office 2019 Home & Student" }
                elseif ($name -match '(?i)ProPlus|Professional') { "Office 2019 Pro" }
                else { "Office 2019" }
            } elseif ($name -match '(?i)Office16|Office\s*16|2016') {
                if ($name -match '(?i)HomeBusiness|Home_Business') { "Office 2016 H&B" }
                elseif ($name -match '(?i)HomeStudent|Home_Student') { "Office 2016 Home & Student" }
                elseif ($name -match '(?i)ProPlus|Professional') { "Office 2016 Pro" }
                else { "Office 2016" }
            } elseif ($name -match '(?i)Office15|Office\s*15|2013') {
                "Office 2013"
            } elseif ($name -match '(?i)Office14|Office\s*14|2010') {
                "Office 2010"
            } elseif ($name -match '(?i)Office\s*(\d+)') {
                "Office " + $Matches[1]
            } else {
                "Office"
            }

            $rawChan = if ($chan) { $chan } else { $desc }
            $chType = if ($rawChan -match '(?i)KMS|GVLK') {
                'KMS'
            } elseif ($rawChan -match '(?i)MAK') {
                'MAK'
            } elseif ($rawChan -match '(?i)RETAIL|ESD|MSDN') {
                'Retail'
            } elseif ($rawChan -match '(?i)OEM') {
                'OEM'
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
        if ($c2rProd -match '(?i)O365|M365|Microsoft\s*365|365ProPlus|365Business') {
            return @{ Badge = 'M365 (Act)'; Detail = "Microsoft 365 ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)2024') {
            $ed = if ($c2rProd -match '(?i)HomeBusiness') { '2024 H&B Retail' } elseif ($c2rProd -match '(?i)ProPlus') { '2024 Pro Retail' } else { '2024 Retail' }
            return @{ Badge = $ed; Detail = "Microsoft Office 2024 Retail/ESD ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)2021') {
            $ed = if ($c2rProd -match '(?i)HomeBusiness') { '2021 H&B Retail' } elseif ($c2rProd -match '(?i)ProPlus') { '2021 Pro Retail' } elseif ($c2rProd -match '(?i)HomeStudent') { '2021 Home & Student' } else { '2021 Retail' }
            return @{ Badge = $ed; Detail = "Microsoft Office 2021 Retail/ESD ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)2019') {
            $ed = if ($c2rProd -match '(?i)HomeBusiness') { '2019 H&B Retail' } elseif ($c2rProd -match '(?i)ProPlus') { '2019 Pro Retail' } else { '2019 Retail' }
            return @{ Badge = $ed; Detail = "Microsoft Office 2019 Retail/ESD ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)2016') {
            $ed = if ($c2rProd -match '(?i)HomeBusiness') { '2016 H&B Retail' } elseif ($c2rProd -match '(?i)ProPlus') { '2016 Pro Retail' } else { '2016 (Inst)' }
            return @{ Badge = $ed; Detail = "Office 2016 ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)2013') {
            return @{ Badge = '2013 (Inst)'; Detail = "Office 2013 ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)2010') {
            return @{ Badge = '2010 (Inst)'; Detail = "Office 2010 ($c2rProd)" }
        } elseif ($c2rProd -match '(?i)ProPlus|Standard|HomeBusiness|HomeStudent|Professional|Enterprise|LTSC|Office') {
            return @{ Badge = 'Office C2R'; Detail = "Office Click-to-Run ($c2rProd)" }
        }
    }

    return @{ Badge = 'None'; Detail = 'No Microsoft Office installation detected' }
}

# --- Helper: Advanced Multi-Method Reachability & Parallel Port Probing ---
function Test-PCConnection([string]$computer) {
    $script:lastConnInfo = @{ Online = $false; Method = 'None'; Detail = 'Host unreachable' }

    if ([string]::IsNullOrWhiteSpace($computer)) {
        return $false
    }

    # 0. Localhost shortcut
    if ($computer -eq 'localhost' -or $computer -eq '127.0.0.1' -or $computer -eq $env:COMPUTERNAME) {
        $script:lastConnInfo = @{ Online = $true; Method = 'Localhost'; Detail = 'Local machine loopback' }
        return $true
    }

    # 1. Skip unassigned / broadcast addresses (*.0 or *.255)
    if ($SkipBroadcast -and ($computer -match '\.(0|255)$')) {
        $script:lastConnInfo = @{ Online = $false; Method = 'Skipped'; Detail = 'Skipped broadcast/network address (*.0 or *.255)' }
        return $false
    }

    # 2. Force Scan Dead Hosts override
    if ($ScanDeadHosts) {
        $script:lastConnInfo = @{ Online = $true; Method = 'Forced (ScanDeadHosts)'; Detail = 'Scan dead hosts active (bypassed reachability check)' }
        return $true
    }

    $method = if ($PingMethod) { $PingMethod.ToLower() } else { 'combined' }
    $timeoutMs = if ($PingTimeoutMs -ge 100) { $PingTimeoutMs } else { 1000 }
    $probes = if ($PingProbes -ge 1) { $PingProbes } else { 2 }
    $ports = if ($script:ParsedProbePorts -and $script:ParsedProbePorts.Count -gt 0) { $script:ParsedProbePorts } else { @(135, 445, 5985, 5986, 3389, 139, 80, 443, 5900) }

    # Helper: Fast UDP Wake-up Datagram (wakes sleeping Wi-Fi / power-saving adapters)
    $sendUdpWakeup = {
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $dummy = [byte[]]@(0x00, 0x01, 0x02, 0x03)
            [void]$udp.Send($dummy, $dummy.Length, $computer, 137)
            $udp.Close()
        } catch { }
    }

    # Helper: .NET ICMP Ping probe with retry
    $testIcmp = {
        for ($p = 1; $p -le $probes; $p++) {
            try {
                $pinger = New-Object System.Net.NetworkInformation.Ping
                $reply = $pinger.Send($computer, $timeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $rtt = $reply.RoundtripTime
                    return @{ Success = $true; Detail = "ICMP Ping ($($rtt)ms, probe $p/$probes)" }
                }
            } catch { }
        }
        return @{ Success = $false; Detail = "ICMP ping timed out ($probes probes @ " + $timeoutMs + "ms)" }
    }

    # Helper: Parallel TCP Multi-Port Probe
    $testTcpParallel = {
        $sockets = @()
        $handles = @()
        $arMap = @{}

        foreach ($port in $ports) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar = $tcp.BeginConnect($computer, $port, $null, $null)
                $sockets += $tcp
                $handles += $ar.AsyncWaitHandle
                $arMap[$port] = @{ Tcp = $tcp; Ar = $ar }
            } catch { }
        }

        $connectedPort = $null
        if ($handles.Count -gt 0) {
            [System.Threading.WaitHandle]::WaitAny($handles, $timeoutMs) | Out-Null
            foreach ($entry in $arMap.GetEnumerator()) {
                $pNum = $entry.Key
                $tObj = $entry.Value.Tcp
                $aObj = $entry.Value.Ar
                try {
                    if ($tObj.Connected -or ($aObj.IsCompleted -and -not $tObj.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectError))) {
                        $tObj.EndConnect($aObj)
                        if ($tObj.Connected) {
                            $connectedPort = $pNum
                            break
                        }
                    }
                } catch { }
            }
        }

        foreach ($s in $sockets) {
            try { $s.Close() } catch { }
        }

        if ($connectedPort) {
            return @{ Success = $true; Port = $connectedPort; Detail = "TCP port $connectedPort open" }
        }
        return @{ Success = $false; Port = $null; Detail = "TCP ports ($($ports -join ',')) closed/timed out" }
    }

    # Helper: ARP Cache check (for local subnet LAN/VLAN)
    $testArp = {
        try {
            $arpOutput = & arp.exe -a 2>$null
            if ($arpOutput -match [regex]::Escape($computer) + '\s+([0-9a-fA-F-]+)\s+dynamic') {
                return @{ Success = $true; Mac = $Matches[1]; Detail = "ARP cache entry verified ($($Matches[1]))" }
            }
        } catch { }
        return @{ Success = $false; Detail = 'No dynamic ARP entry found' }
    }

    switch ($method) {
        'icmp' {
            $icmpRes = & $testIcmp
            if ($icmpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = 'ICMP'; Detail = $icmpRes.Detail }
                return $true
            }
            $script:lastConnInfo = @{ Online = $false; Method = 'ICMP'; Detail = $icmpRes.Detail }
            return $false
        }

        'tcp' {
            $tcpRes = & $testTcpParallel
            if ($tcpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = "TCP:$($tcpRes.Port)"; Detail = $tcpRes.Detail }
                return $true
            }
            $script:lastConnInfo = @{ Online = $false; Method = 'TCP'; Detail = $tcpRes.Detail }
            return $false
        }

        'udptcp' {
            & $sendUdpWakeup
            $tcpRes = & $testTcpParallel
            if ($tcpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = "UDP+TCP:$($tcpRes.Port)"; Detail = $tcpRes.Detail }
                return $true
            }
            $script:lastConnInfo = @{ Online = $false; Method = 'UDP+TCP'; Detail = $tcpRes.Detail }
            return $false
        }

        'arp' {
            $icmpRes = & $testIcmp
            if ($icmpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = 'ICMP'; Detail = $icmpRes.Detail }
                return $true
            }
            $arpRes = & $testArp
            if ($arpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = 'ARP'; Detail = $arpRes.Detail }
                return $true
            }
            $script:lastConnInfo = @{ Online = $false; Method = 'ARP'; Detail = "ICMP and $($arpRes.Detail)" }
            return $false
        }

        default {
            # 'combined' (Best for Wi-Fi & Firewalled Windows PCs)
            & $sendUdpWakeup

            $icmpRes = & $testIcmp
            if ($icmpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = 'ICMP'; Detail = $icmpRes.Detail }
                return $true
            }

            $tcpRes = & $testTcpParallel
            if ($tcpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = "TCP:$($tcpRes.Port)"; Detail = $tcpRes.Detail }
                return $true
            }

            $arpRes = & $testArp
            if ($arpRes.Success) {
                $script:lastConnInfo = @{ Online = $true; Method = 'ARP'; Detail = $arpRes.Detail }
                return $true
            }

            $script:lastConnInfo = @{
                Online = $false
                Method = 'Combined'
                Detail = "Host unreachable (ICMP ping and TCP ports $($ports -join ',') timed out @ " + $timeoutMs + "ms)"
            }
            return $false
        }
    }
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
        [void]$ds.PropertiesToLoad.Add('dnshostname')
        
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

# --- Global Rescued Endpoints Cache (Host -> IP/FQDN) ---
$script:rescuedEndpoints = @{}
$script:subnetHostMap = @{}

# ================= Helper Functions for Deep Penetration & Hardware Extraction =================

function Encode-NetBiosName([string]$name, [byte]$suffix = 0x00) {
    $padded = $name.Trim().ToUpper().PadRight(15, ' ')
    if ($padded.Length -gt 15) { $padded = $padded.Substring(0, 15) }
    $raw = [System.Text.Encoding]::ASCII.GetBytes($padded)
    $encoded = New-Object byte[] 32
    for ($i = 0; $i -lt 15; $i++) {
        $b = $raw[$i]
        $encoded[$i * 2] = [byte]((($b -shr 4) -band 0x0F) + 0x41)
        $encoded[$i * 2 + 1] = [byte](($b -band 0x0F) + 0x41)
    }
    $encoded[30] = [byte]((($suffix -shr 4) -band 0x0F) + 0x41)
    $encoded[31] = [byte](($suffix -band 0x0F) + 0x41)
    return $encoded
}

function Build-NetBiosNameQueryPacket([string]$name) {
    $pkt = New-Object System.Collections.Generic.List[byte]
    # Transaction ID (0x1234)
    $pkt.Add(0x12); $pkt.Add(0x34)
    # Flags: 0x0110 (Query, Recursion Desired, Broadcast)
    $pkt.Add(0x01); $pkt.Add(0x10)
    # Questions: 1
    $pkt.Add(0x00); $pkt.Add(0x01)
    # Answers, Authority, Additional: 0
    $pkt.Add(0x00); $pkt.Add(0x00)
    $pkt.Add(0x00); $pkt.Add(0x00)
    $pkt.Add(0x00); $pkt.Add(0x00)
    # Question Name: Length = 32
    $pkt.Add(0x20)
    $enc = Encode-NetBiosName -name $name -suffix 0x00
    foreach ($b in $enc) { $pkt.Add($b) }
    $pkt.Add(0x00) # Terminator
    # Type: NB (0x0020), Class: IN (0x0001)
    $pkt.Add(0x00); $pkt.Add(0x20)
    $pkt.Add(0x00); $pkt.Add(0x01)
    return $pkt.ToArray()
}

function Build-NetBiosNodeStatusPacket() {
    $pkt = New-Object System.Collections.Generic.List[byte]
    $pkt.Add(0xAB); $pkt.Add(0xCD) # Transaction ID
    $pkt.Add(0x00); $pkt.Add(0x00) # Query
    $pkt.Add(0x00); $pkt.Add(0x01) # Question: 1
    $pkt.Add(0x00); $pkt.Add(0x00)
    $pkt.Add(0x00); $pkt.Add(0x00)
    $pkt.Add(0x00); $pkt.Add(0x00)
    $pkt.Add(0x20) # Length 32
    # Wildcard '*' (0x2A) padded with spaces
    $enc = Encode-NetBiosName -name '*' -suffix 0x00
    foreach ($b in $enc) { $pkt.Add($b) }
    $pkt.Add(0x00)
    $pkt.Add(0x00); $pkt.Add(0x21) # Type: NBSTAT (0x0021)
    $pkt.Add(0x00); $pkt.Add(0x01) # Class: IN (0x0001)
    return $pkt.ToArray()
}

function Resolve-NetBiosDirectQuery([string]$targetHostName, [string]$subnetPrefix = '') {
    $cleanName = ($targetHostName -split '\.')[0].Trim()
    if ([string]::IsNullOrWhiteSpace($cleanName)) { return $null }

    $destEndpoints = [System.Collections.Generic.List[System.Net.IPEndPoint]]::new()
    if (-not [string]::IsNullOrWhiteSpace($subnetPrefix)) {
        try {
            $destEndpoints.Add([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse("$subnetPrefix.255"), 137))
        } catch {}
    }
    $destEndpoints.Add([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, 137))

    $pkt = Build-NetBiosNameQueryPacket -name $cleanName
    $udp = $null
    $foundIps = [System.Collections.Generic.List[string]]::new()
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 400

        foreach ($ep in $destEndpoints) {
            try {
                [void]$udp.Send($pkt, $pkt.Length, $ep)
            } catch {}
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 600) {
            try {
                $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $resp = $udp.Receive([ref]$remoteEp)
                if ($resp -and $resp.Length -ge 12) {
                    $rIp = $remoteEp.Address.ToString()
                    if ($rIp -notmatch '^(127\.|169\.254\.)' -and -not $foundIps.Contains($rIp)) {
                        $foundIps.Add($rIp)
                    }
                }
            } catch {
                break
            }
        }
    } catch {}
    finally {
        if ($udp) {
            try { $udp.Close() } catch {}
        }
    }

    return $foundIps
}

function Map-SubnetLiveHosts([string]$subnetPrefix) {
    if ([string]::IsNullOrWhiteSpace($subnetPrefix)) { return @{} }
    if ($script:subnetHostMap.ContainsKey($subnetPrefix)) {
        return $script:subnetHostMap[$subnetPrefix]
    }

    $map = @{}
    $pkt = Build-NetBiosNodeStatusPacket
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 500

        # Fast parallel blast: send Unicast NBSTAT query to all 254 hosts in the /24 subnet
        for ($i = 1; $i -le 254; $i++) {
            $destIp = "$subnetPrefix.$i"
            try {
                [void]$udp.Send($pkt, $pkt.Length, $destIp, 137)
            } catch {}
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 1200) {
            try {
                $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $resp = $udp.Receive([ref]$remoteEp)
                if ($resp -and $resp.Length -gt 56) {
                    $rIp = $remoteEp.Address.ToString()
                    # Parse NetBIOS names count at offset 56
                    $numNames = [int]$resp[56]
                    $offset = 57
                    for ($n = 0; $n -lt $numNames; $n++) {
                        if (($offset + 18) -le $resp.Length) {
                            $rawNameBytes = New-Object byte[] 15
                            [System.Array]::Copy($resp, $offset, $rawNameBytes, 0, 15)
                            $nameStr = ([System.Text.Encoding]::ASCII.GetString($rawNameBytes)).Trim()
                            $suffixByte = $resp[$offset + 15]
                            $nameFlags = [BitConverter]::ToUInt16($resp, $offset + 16)
                            $isGroup = ($nameFlags -band 0x8000) -ne 0

                            # Suffix 0x00 or 0x20 and not a group/workgroup name -> Machine Name!
                            if (-not $isGroup -and ($suffixByte -eq 0x00 -or $suffixByte -eq 0x20) -and -not [string]::IsNullOrWhiteSpace($nameStr)) {
                                $uName = $nameStr.ToUpper()
                                if (-not $map.ContainsKey($uName)) {
                                    $map[$uName] = $rIp
                                }
                            }
                            $offset += 18
                        }
                    }
                }
            } catch {
                break
            }
        }
    } catch {}
    finally {
        if ($udp) {
            try { $udp.Close() } catch {}
        }
    }

    $script:subnetHostMap[$subnetPrefix] = $map
    return $map
}

function Find-GhostDnsTrueIP([string]$targetHostName, [string]$staleIp = '') {
    $shortName = ($targetHostName -split '\.')[0].Trim().ToUpper()
    if ([string]::IsNullOrWhiteSpace($shortName)) { return $null }

    $subnetPrefix = ''
    if ($staleIp -match '^(\d+\.\d+\.\d+)\.\d+$') {
        $subnetPrefix = $matches[1]
    }

    # Step 1: Direct UDP 137 NetBIOS Name Query
    $directIps = Resolve-NetBiosDirectQuery -targetHostName $shortName -subnetPrefix $subnetPrefix
    if ($directIps -and $directIps.Count -gt 0) {
        foreach ($dIp in $directIps) {
            if ($dIp -ne $staleIp) {
                return $dIp
            }
        }
        return $directIps[0]
    }

    # Step 2: Subnet Hostname Sweep Cache (/24 sweep via Unicast UDP 137 NBSTAT)
    if (-not [string]::IsNullOrWhiteSpace($subnetPrefix)) {
        $subMap = Map-SubnetLiveHosts -subnetPrefix $subnetPrefix
        if ($subMap -and $subMap.ContainsKey($shortName)) {
            return $subMap[$shortName]
        }
    }

    return $null
}

function Invoke-RemoteDnsSelfHeal([string]$targetEndpoint) {
    if ([string]::IsNullOrWhiteSpace($targetEndpoint)) { return }
    try {
        # Remote Trigger via CIM / WMI Win32_Process.Create
        $opt = New-CimSessionOption -Protocol Dcom
        $sess = New-CimSession -ComputerName $targetEndpoint -SessionOption $opt -OperationTimeoutSec 8 -ErrorAction Stop
        [void](Invoke-CimMethod -CimSession $sess -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c ipconfig /registerdns & nbtstat -RR' } -ErrorAction SilentlyContinue)
        Remove-CimSession $sess -ErrorAction SilentlyContinue
    } catch {
        # Fallback via PowerShell Remoting
        try {
            Invoke-Command -ComputerName $targetEndpoint -ScriptBlock {
                Start-Process cmd.exe -ArgumentList '/c ipconfig /registerdns & nbtstat -RR' -WindowStyle Hidden -ErrorAction SilentlyContinue
            } -OperationTimeoutSec 8 -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Resolve-PCTargets([string]$pc, [hashtable]$adInfo = $null, [hashtable]$masterDict = $null) {
    $targets = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $cleanPc = $pc.Trim()
    $shortName = ($cleanPc -split '\.')[0]

    $addTarget = {
        param([string]$target, [string]$source)
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            $t = $target.Trim()
            if (-not $seen.Contains($t)) {
                [void]$seen.Add($t)
                $targets.Add(@{ Address = $t; Source = $source })
            }
        }
    }

    # 1. Short Hostname
    & $addTarget $shortName 'ShortHostname'

    # 2. AD FQDN
    if ($adInfo -and $adInfo.AD_DNSHostName) {
        & $addTarget $adInfo.AD_DNSHostName 'AD_FQDN'
    }

    # 3. DNS IPv4 Resolution (All IPs returned by DNS)
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($cleanPc) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }
        foreach ($ip in $ips) {
            $ipStr = $ip.ToString()
            if ($ipStr -notmatch '^(127\.|169\.254\.)') {
                & $addTarget $ipStr 'DNS_IPv4'
            }
        }
    } catch {}

    # 4. Direct NetBIOS / Subnet True-IP Discovery (Ghost DNS Buster)
    try {
        $staleIpCandidate = ''
        if ($ips -and $ips.Count -gt 0) {
            $staleIpCandidate = $ips[0].ToString()
        }
        $trueIp = Find-GhostDnsTrueIP -targetHostName $shortName -staleIp $staleIpCandidate
        if ($trueIp -and $trueIp -notmatch '^(127\.|169\.254\.)') {
            & $addTarget $trueIp 'GhostDNS_Hunter'
        }
    } catch {}

    # 5. mDNS (.local)
    if ($cleanPc -notmatch '\.') {
        & $addTarget "$cleanPc.local" 'mDNS'
    }

    # 6. Last Known IP from Master DB (strictly verified by hostname later)
    if ($masterDict) {
        $mKey = $cleanPc.ToUpper()
        $mShort = $shortName.ToUpper()
        $oldRec = if ($masterDict.Contains($mKey)) { $masterDict[$mKey] } elseif ($masterDict.Contains($mShort)) { $masterDict[$mShort] } else { $null }
        if ($oldRec -and $oldRec.IP) {
            foreach ($candIp in ($oldRec.IP -split '[,;\s]+')) {
                if ($candIp -match '^\d+\.\d+\.\d+\.\d+$' -and $candIp -notmatch '^(127\.|169\.254\.)') {
                    & $addTarget $candIp 'MasterDB_LastKnown'
                }
            }
        }
    }

    return $targets
}

function Test-EndpointAlive([string]$endpoint, [int]$timeoutMs = 1000) {
    if ([string]::IsNullOrWhiteSpace($endpoint)) { return $false }
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $dummy = [byte[]]@(0x00, 0x01, 0x02, 0x03)
        [void]$udp.Send($dummy, $dummy.Length, $endpoint, 137)
        $udp.Close()
    } catch {}

    $testPorts = @(135, 445, 5985, 3389, 139, 5900)
    foreach ($p in $testPorts) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($endpoint, $p, $null, $null)
            $waitOk = $ar.AsyncWaitHandle.WaitOne($timeoutMs, $false)
            if ($waitOk -and $tcp.Connected) {
                $tcp.EndConnect($ar)
                $tcp.Close()
                return $true
            }
            $tcp.Close()
        } catch {}
    }

    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $reply = $pinger.Send($endpoint, $timeoutMs)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            return $true
        }
    } catch {}

    return $false
}

function Get-HardwareFromCimSession {
    param(
        $s,
        [string]$pcTarget,
        [bool]$isLocal,
        [string]$prevWinLicense = '-',
        [string]$prevOfficeLicense = '-',
        [string]$prevOfficeDetail = '-',
        [hashtable]$ad = @{},
        [string]$methodName = 'DCOM',
        [string]$statusDetail = 'Hardware scan completed successfully',
        [bool]$skipServerCheck = $true
    )
    try {
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
            $cs = Get-CimInstance Win32_ComputerSystem -CimSession $s -OperationTimeoutSec 15 -ErrorAction Stop
            $bios = Get-CimInstance Win32_BIOS -CimSession $s -OperationTimeoutSec 15 -ErrorAction Stop
            $os = Get-CimInstance Win32_OperatingSystem -CimSession $s -OperationTimeoutSec 15 -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor -CimSession $s -OperationTimeoutSec 15 -ErrorAction Stop | Select-Object -First 1
            $disk = Get-CimInstance Win32_DiskDrive -CimSession $s -OperationTimeoutSec 15 -ErrorAction SilentlyContinue
            $gpu = Get-CimInstance Win32_VideoController -CimSession $s -OperationTimeoutSec 15 -ErrorAction SilentlyContinue
            $ram = Get-CimInstance Win32_PhysicalMemory -CimSession $s -OperationTimeoutSec 15 -ErrorAction SilentlyContinue
            $net = Get-CimInstance Win32_NetworkAdapterConfiguration -CimSession $s -OperationTimeoutSec 15 -ErrorAction SilentlyContinue | Where-Object IPEnabled
            $cDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -CimSession $s -OperationTimeoutSec 15 -ErrorAction SilentlyContinue
        }

        if ($skipServerCheck -and -not $isLocal -and $os -and $os.ProductType -and $os.ProductType -ne 1) {
            Write-Host "  [SKIP SERVER] Skipping $pcTarget (Detected Server OS: $($os.Caption))" -ForegroundColor Yellow
            return @{ SkipServer = $true }
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

        $osBuildStr = [string]$os.BuildNumber
        try {
            if ($isLocal) {
                $ntKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
                if ($ntKey) {
                    $ubr = $ntKey.GetValue('UBR')
                    if ($null -ne $ubr) {
                        $osBuildStr = '{0}.{1}' -f $os.BuildNumber, $ubr
                    }
                    $ntKey.Close()
                }
            } elseif ($s) {
                $regParams = @{
                    hDefKey = 2147483650
                    sSubKeyName = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
                }
                $ubrRes = Invoke-CimMethod -CimSession $s -ClassName StdRegProv -MethodName GetDWORDValue -Arguments ($regParams + @{ sValueName = 'UBR' }) -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
                if ($ubrRes -and $null -ne $ubrRes.uValue) {
                    $osBuildStr = '{0}.{1}' -f $os.BuildNumber, $ubrRes.uValue
                }
            }
        } catch {}

        $winLicenseStr = '-'
        $officeLicenseStr = '-'
        $officeDetailStr = '-'
        try {
            $slpItems = if ($isLocal) {
                @(Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey is not null" -ErrorAction SilentlyContinue)
            } elseif ($s) {
                @(Get-CimInstance SoftwareLicensingProduct -CimSession $s -Filter "PartialProductKey is not null" -OperationTimeoutSec 20 -ErrorAction SilentlyContinue)
            } else { @() }

            $winLic = $slpItems | Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } | Sort-Object LicenseStatus -Descending | Select-Object -First 1
            if (-not $winLic) {
                $winLic = $slpItems | Where-Object { $_.Name -match '(?i)Windows' -and $null -ne $_.LicenseStatus } | Sort-Object LicenseStatus -Descending | Select-Object -First 1
            }
            if ($winLic) {
                $rawChan = if ($winLic.ProductKeyChannel) { $winLic.ProductKeyChannel } else { [string]$winLic.Description }
                $chan = if ($rawChan -match '(?i)OEM') { 'OEM' }
                    elseif ($rawChan -match '(?i)VOLUME_KMS|Volume:GVLK|KMS') { 'Volume (KMS)' }
                    elseif ($rawChan -match '(?i)VOLUME_MAK|MAK') { 'Volume (MAK)' }
                    elseif ($rawChan -match '(?i)Volume') { 'Volume' }
                    elseif ($rawChan -match '(?i)RETAIL') { 'Retail' }
                    else { 'OEM/Retail' }
                $actStatus = if ($winLic.LicenseStatus -eq 1) { 'Activated' } elseif ($winLic.LicenseStatus -eq 0) { 'Unlicensed' } else { 'Grace' }
                $winLicenseStr = "$chan ($actStatus)"
            } else {
                try {
                    $sls = if ($isLocal) {
                        Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
                    } elseif ($s) {
                        Get-CimInstance SoftwareLicensingService -CimSession $s -OperationTimeoutSec 10 -ErrorAction SilentlyContinue
                    } else { $null }
                    if ($sls) {
                        if ($sls.OA3xOriginalProductKey) { $winLicenseStr = 'OEM (Activated)' }
                        elseif ($sls.KeyManagementServiceMachine) { $winLicenseStr = 'Volume (KMS) (Activated)' }
                    }
                } catch {}
            }

            if (($winLicenseStr -eq '-' -or [string]::IsNullOrWhiteSpace($winLicenseStr)) -and $prevWinLicense -ne '-') {
                $winLicenseStr = $prevWinLicense
            }

            $c2rProdIds = ''
            if ($isLocal) {
                $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
                if ($c2r -and $c2r.ProductReleaseIds) { $c2rProdIds = [string]$c2r.ProductReleaseIds }
                if (-not $c2rProdIds) {
                    $uninstPaths = @(
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    )
                    $offApp = Get-ItemProperty $uninstPaths -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -match '(?i)^(Microsoft 365|Microsoft Office (Professional|Standard|Home|Business|Enterprise|LTSC|365|20\d{2}))' -and $_.DisplayName -notmatch '(?i)MUI|Proof|Shared|Component|Viewer|Redistributable|Visio|Project|Connector' } |
                        Select-Object -ExpandProperty DisplayName -First 1
                    if ($offApp) { $c2rProdIds = [string]$offApp }
                }
            } elseif ($s) {
                try {
                    $c2rRes = Invoke-CimMethod -CimSession $s -Namespace 'root\default' -ClassName StdRegProv -MethodName GetStringValue -Arguments @{
                        hDefKey     = [uint32]2147483650
                        sSubKeyName = 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
                        sValueName  = 'ProductReleaseIds'
                    } -OperationTimeoutSec 10 -ErrorAction SilentlyContinue
                    if ($c2rRes -and $c2rRes.sValue) { $c2rProdIds = [string]$c2rRes.sValue }
                } catch {}
            }

            $officeSlp = @($slpItems | Where-Object { $_.Name -match 'Office|O16|O15|O14|0ff1ce15-a989-479d-af46-f275c6370663' })
            $offParsed = Parse-OfficeLicenseInfo $c2rProdIds $officeSlp
            $officeLicenseStr = $offParsed.Badge
            $officeDetailStr  = $offParsed.Detail
        } catch {}

        if (($winLicenseStr -eq '-' -or [string]::IsNullOrWhiteSpace($winLicenseStr)) -and $prevWinLicense -ne '-') {
            $winLicenseStr = $prevWinLicense
        }
        if (($officeLicenseStr -in @('-', 'None') -or [string]::IsNullOrWhiteSpace($officeLicenseStr)) -and $prevOfficeLicense -notin @('-', 'None')) {
            $officeLicenseStr = $prevOfficeLicense
            $officeDetailStr  = if ($prevOfficeDetail -and $prevOfficeDetail -ne '-') { $prevOfficeDetail } else { $prevOfficeLicense }
        }

        $ramVal = if ($ram) { [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB) } else { '-' }
        $disksVal = if ($disk) { ($disk | ForEach-Object { "$($_.Model) $([math]::Round($_.Size/1GB))GB" }) -join '; ' } else { '-' }
        $gpuVal = if ($gpu) { ($gpu.Name) -join '; ' } else { '-' }
        $ipVal = if ($net) { ($net.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', ' } else { '-' }
        $macVal = if ($net) { ($net.MACAddress) -join ', ' } else { '-' }

        return New-HardwareRecord @{
            PCName         = $cs.Name
            Status         = 'OK'
            Method         = $methodName
            Status_Detail  = $statusDetail
            Fail_Count     = 0
            Win_License    = $winLicenseStr
            Office_License = $officeLicenseStr
            Office_Detail  = $officeDetailStr
            User           = $cs.UserName
            Maker          = $cs.Manufacturer
            Model          = $cs.Model
            Serial         = $bios.SerialNumber
            CPU            = if ($cpu) { $cpu.Name } else { '-' }
            Cores          = if ($cpu) { $cpu.NumberOfCores } else { '-' }
            RAM_GB         = $ramVal
            Disk_C_Free    = $cDiskSummary
            Disks          = $disksVal
            GPU            = $gpuVal
            OS             = $os.Caption
            OSBuild        = $osBuildStr
            Last_Boot      = $lastBootStr
            Uptime         = $uptimeStr
            AD_LastLogon   = $ad.AD_LastLogon
            AD_OU          = $ad.AD_OU
            IP             = $ipVal
            MAC            = $macVal
            Scan_Count     = 1
            First_Seen     = Get-Date -Format 'yyyy-MM-dd HH:mm'
            Last_Scan      = Get-Date -Format 'yyyy-MM-dd HH:mm'
        }
    } catch {
        return $null
    }
}

function Get-HardwareFromRemoteRegistry {
    param(
        [string]$targetAddress,
        [string]$expectedHost,
        [string]$prevWinLicense = '-',
        [string]$prevOfficeLicense = '-',
        [string]$prevOfficeDetail = '-',
        [hashtable]$ad = @{}
    )
    try {
        $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $targetAddress)
        if (-not $reg) { return $null }

        # Verify hostname to prevent DHCP collision
        $compKey = $reg.OpenSubKey('SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName')
        $actualName = if ($compKey) { [string]$compKey.GetValue('ComputerName') } else { '' }
        if ($compKey) { $compKey.Close() }

        $expectedShort = ($expectedHost -split '\.')[0]
        if ($actualName -and ($actualName -inotmatch "^$([regex]::Escape($expectedShort))$")) {
            $reg.Close()
            return $null
        }
        $reportedName = if ($actualName) { $actualName } else { $expectedShort }

        # CPU & Cores
        $cpuKey = $reg.OpenSubKey('HARDWARE\DESCRIPTION\System\CentralProcessor\0')
        $cpuName = if ($cpuKey) { [string]$cpuKey.GetValue('ProcessorNameString') } else { '-' }
        if ($cpuKey) { $cpuKey.Close() }

        $cpuRoot = $reg.OpenSubKey('HARDWARE\DESCRIPTION\System\CentralProcessor')
        $cores = if ($cpuRoot) { ($cpuRoot.GetSubKeyNames()).Count } else { 0 }
        if ($cpuRoot) { $cpuRoot.Close() }

        # BIOS
        $biosKey = $reg.OpenSubKey('HARDWARE\DESCRIPTION\System\BIOS')
        $maker = if ($biosKey) { [string]$biosKey.GetValue('SystemManufacturer') } else { '-' }
        $model = if ($biosKey) { [string]$biosKey.GetValue('SystemProductName') } else { '-' }
        $serial = if ($biosKey) {
            $s = [string]$biosKey.GetValue('BaseBoardSerialNumber')
            if (-not $s) { $s = [string]$biosKey.GetValue('SystemSerialNumber') }
            $s
        } else { '-' }
        if ($biosKey) { $biosKey.Close() }

        # OS & Build
        $ntKey = $reg.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        $osCaption = if ($ntKey) { [string]$ntKey.GetValue('ProductName') } else { 'Windows' }
        $currentBuild = if ($ntKey) { [string]$ntKey.GetValue('CurrentBuild') } else { '-' }
        $ubr = if ($ntKey) { $ntKey.GetValue('UBR') } else { $null }
        $osBuild = if ($null -ne $ubr -and $currentBuild -ne '-') { '{0}.{1}' -f $currentBuild, $ubr } else { $currentBuild }
        if ($ntKey) { $ntKey.Close() }

        # User
        $userKey = $reg.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI')
        $lastUser = if ($userKey) { [string]$userKey.GetValue('LastLoggedOnUser') } else { '-' }
        if ($userKey) { $userKey.Close() }

        # Office ClickToRun
        $c2rKey = $reg.OpenSubKey('SOFTWARE\Microsoft\Office\ClickToRun\Configuration')
        $c2rProds = if ($c2rKey) { [string]$c2rKey.GetValue('ProductReleaseIds') } else { '' }
        if ($c2rKey) { $c2rKey.Close() }

        $offParsed = if ($c2rProds) { Parse-OfficeLicenseInfo $c2rProds @() } else { @{ Badge = $prevOfficeLicense; Detail = $prevOfficeDetail } }

        $reg.Close()

        return New-HardwareRecord @{
            PCName         = $reportedName
            Status         = 'OK'
            Method         = '⚡ Reg-445'
            Status_Detail  = 'Rescued via Remote Registry over SMB Port 445'
            Fail_Count     = 0
            Win_License    = if ($prevWinLicense -and $prevWinLicense -ne '-') { $prevWinLicense } else { 'OEM/Retail (Activated)' }
            Office_License = if ($offParsed.Badge -and $offParsed.Badge -notin @('-', 'None')) { $offParsed.Badge } else { $prevOfficeLicense }
            Office_Detail  = if ($offParsed.Detail -and $offParsed.Detail -ne '-') { $offParsed.Detail } else { $prevOfficeDetail }
            User           = $lastUser
            Maker          = $maker
            Model          = $model
            Serial         = $serial
            CPU            = $cpuName
            Cores          = $cores
            RAM_GB         = '-'
            Disk_C_Free    = '-'
            Disks          = '-'
            GPU            = '-'
            OS             = $osCaption
            OSBuild        = $osBuild
            Last_Boot      = '-'
            Uptime         = '-'
            AD_LastLogon   = $ad.AD_LastLogon
            AD_OU          = $ad.AD_OU
            IP             = $targetAddress
            MAC            = '-'
            Scan_Count     = 1
            First_Seen     = Get-Date -Format 'yyyy-MM-dd HH:mm'
            Last_Scan      = Get-Date -Format 'yyyy-MM-dd HH:mm'
        }
    } catch {
        return $null
    }
}

function Get-HardwareFromPSRemoting {
    param(
        [string]$targetAddress,
        [string]$expectedHost,
        [string]$prevWinLicense = '-',
        [string]$prevOfficeLicense = '-',
        [string]$prevOfficeDetail = '-',
        [hashtable]$ad = @{}
    )
    try {
        $expectedShort = ($expectedHost -split '\.')[0]
        $remoteRes = Invoke-Command -ComputerName $targetAddress -ScriptBlock {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            $disk = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue
            $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            $ram = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
            $net = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object IPEnabled
            $cDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Name = $cs.Name; User = $cs.UserName; Maker = $cs.Manufacturer; Model = $cs.Model
                Serial = $bios.SerialNumber; CPU = $cpu.Name; Cores = $cpu.NumberOfCores
                RAM = ($ram | Measure-Object Capacity -Sum).Sum
                Disks = ($disk | ForEach-Object { "$($_.Model) $([math]::Round($_.Size/1GB))GB" }) -join '; '
                GPU = ($gpu.Name) -join '; '
                OS = $os.Caption; OSBuild = $os.BuildNumber; LastBoot = $os.LastBootUpTime
                IP = ($net.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '
                MAC = ($net.MACAddress) -join ', '
                C_Free = $cDrive.FreeSpace; C_Total = $cDrive.Size
            }
        } -OperationTimeoutSec 15 -ErrorAction Stop

        if (-not $remoteRes) { return $null }

        if ($remoteRes.Name -and ($remoteRes.Name -inotmatch "^$([regex]::Escape($expectedShort))$")) {
            return $null
        }

        $ramGb = if ($remoteRes.RAM -gt 0) { [math]::Round($remoteRes.RAM / 1GB) } else { '-' }
        $cSummary = '-'
        if ($remoteRes.C_Total -gt 0) {
            $fGB = [math]::Round($remoteRes.C_Free / 1GB, 1)
            $tGB = [math]::Round($remoteRes.C_Total / 1GB, 0)
            $pct = [math]::Round(($remoteRes.C_Free / $remoteRes.C_Total) * 100, 0)
            $cSummary = "$fGB / $tGB GB ($pct% free)"
        }

        return New-HardwareRecord @{
            PCName         = if ($remoteRes.Name) { $remoteRes.Name } else { $expectedShort }
            Status         = 'OK'
            Method         = '⚡ PS-Remote'
            Status_Detail  = 'Rescued via PowerShell Remoting (Invoke-Command)'
            Fail_Count     = 0
            Win_License    = if ($prevWinLicense -and $prevWinLicense -ne '-') { $prevWinLicense } else { 'OEM/Retail (Activated)' }
            Office_License = $prevOfficeLicense
            Office_Detail  = $prevOfficeDetail
            User           = $remoteRes.User
            Maker          = $remoteRes.Maker
            Model          = $remoteRes.Model
            Serial         = $remoteRes.Serial
            CPU            = $remoteRes.CPU
            Cores          = $remoteRes.Cores
            RAM_GB         = $ramGb
            Disk_C_Free    = $cSummary
            Disks          = $remoteRes.Disks
            GPU            = $remoteRes.GPU
            OS             = $remoteRes.OS
            OSBuild        = $remoteRes.OSBuild
            Last_Boot      = '-'
            Uptime         = '-'
            AD_LastLogon   = $ad.AD_LastLogon
            AD_OU          = $ad.AD_OU
            IP             = if ($remoteRes.IP) { $remoteRes.IP } else { $targetAddress }
            MAC            = $remoteRes.MAC
            Scan_Count     = 1
            First_Seen     = Get-Date -Format 'yyyy-MM-dd HH:mm'
            Last_Scan      = Get-Date -Format 'yyyy-MM-dd HH:mm'
        }
    } catch {
        return $null
    }
}

function Invoke-DeepPenetrationScan {
    param(
        [string]$pc,
        [hashtable]$ad,
        [object]$oldRecord,
        [int]$prevFailCount = 0,
        [string]$prevWinLicense = '-',
        [string]$prevOfficeLicense = '-',
        [string]$prevOfficeDetail = '-',
        [hashtable]$masterDict = @{},
        [bool]$wasError = $false,
        [bool]$healDns = $true
    )

    $shortName = ($pc -split '\.')[0]
    $candidates = Resolve-PCTargets -pc $pc -adInfo $ad -masterDict $masterDict

    # Smart Fast-Gate Check
    $hasAlive = $false
    $responsiveTarget = $null
    if ($wasError) {
        $hasAlive = $true
    } else {
        foreach ($cand in $candidates) {
            if (Test-EndpointAlive -endpoint $cand.Address -timeoutMs 800) {
                $hasAlive = $true
                $responsiveTarget = $cand.Address
                break
            }
        }
    }

    if (-not $hasAlive) {
        return $null
    }

    $orderedTargets = [System.Collections.Generic.List[string]]::new()
    if ($responsiveTarget) { $orderedTargets.Add($responsiveTarget) }
    foreach ($c in $candidates) {
        if (-not $orderedTargets.Contains($c.Address)) {
            $orderedTargets.Add($c.Address)
        }
    }

    # Stage 1: WinRM (WSMAN Port 5985)
    foreach ($cand in $orderedTargets) {
        try {
            $opt = New-CimSessionOption -Protocol Wsman
            $s = New-CimSession -ComputerName $cand -SessionOption $opt -OperationTimeoutSec 10 -ErrorAction Stop
            $cs = Get-CimInstance Win32_ComputerSystem -CimSession $s -OperationTimeoutSec 10 -ErrorAction Stop
            if ($cs -and $cs.Name -and ($cs.Name -ieq $shortName)) {
                $statusMsg = "Rescued via WinRM (WSMAN:5985 on $cand)"
                $dnsRescued = $false
                if ($cand -match '^\d+\.\d+\.\d+\.\d+$') {
                    try {
                        $dnsIps = @([System.Net.Dns]::GetHostAddresses($shortName) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })
                        if ($dnsIps.Count -gt 0 -and ($dnsIps -notcontains $cand)) {
                            $dnsRescued = $true
                            if ($healDns) {
                                $statusMsg = "Ghost DNS Rescued (DNS: $($dnsIps[0]) -> Live: $cand | Triggered /registerdns)"
                                Invoke-RemoteDnsSelfHeal -targetEndpoint $cand
                            } else {
                                $statusMsg = "Ghost DNS Rescued (DNS: $($dnsIps[0]) -> Live: $cand | DNS healing disabled)"
                            }
                        }
                    } catch {}
                }

                $rec = Get-HardwareFromCimSession -s $s -pcTarget $cand -isLocal $false `
                    -prevWinLicense $prevWinLicense -prevOfficeLicense $prevOfficeLicense -prevOfficeDetail $prevOfficeDetail `
                    -ad $ad -methodName '⚡ WinRM' -statusDetail $statusMsg
                Remove-CimSession $s -ErrorAction SilentlyContinue
                if ($rec) {
                    $script:rescuedEndpoints[$pc.ToUpper()] = $cand
                    return $rec
                }
            } else {
                Remove-CimSession $s -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # Stage 2: Direct IPv4 via Legacy WMI / DCOM (Forces NTLM over Kerberos)
    $ipCandidates = @($orderedTargets | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    foreach ($ipCand in $ipCandidates) {
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $s = New-CimSession -ComputerName $ipCand -SessionOption $opt -OperationTimeoutSec 12 -ErrorAction Stop
            $cs = Get-CimInstance Win32_ComputerSystem -CimSession $s -OperationTimeoutSec 10 -ErrorAction Stop
            if ($cs -and $cs.Name -and ($cs.Name -ieq $shortName)) {
                $statusMsg = "Rescued via Direct IP DCOM ($ipCand)"
                $dnsRescued = $false
                try {
                    $dnsIps = @([System.Net.Dns]::GetHostAddresses($shortName) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })
                    if ($dnsIps.Count -gt 0 -and ($dnsIps -notcontains $ipCand)) {
                        $dnsRescued = $true
                        if ($healDns) {
                            $statusMsg = "Ghost DNS Rescued (DNS: $($dnsIps[0]) -> Live: $ipCand | Triggered /registerdns)"
                            Invoke-RemoteDnsSelfHeal -targetEndpoint $ipCand
                        } else {
                            $statusMsg = "Ghost DNS Rescued (DNS: $($dnsIps[0]) -> Live: $ipCand | DNS healing disabled)"
                        }
                    }
                } catch {}

                $rec = Get-HardwareFromCimSession -s $s -pcTarget $ipCand -isLocal $false `
                    -prevWinLicense $prevWinLicense -prevOfficeLicense $prevOfficeLicense -prevOfficeDetail $prevOfficeDetail `
                    -ad $ad -methodName '⚡ IP-WMI' -statusDetail $statusMsg
                Remove-CimSession $s -ErrorAction SilentlyContinue
                if ($rec) {
                    $script:rescuedEndpoints[$pc.ToUpper()] = $ipCand
                    return $rec
                }
            } else {
                Remove-CimSession $s -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # Stage 3: PowerShell Remoting (Invoke-Command)
    foreach ($cand in $orderedTargets) {
        $rec = Get-HardwareFromPSRemoting -targetAddress $cand -expectedHost $pc `
            -prevWinLicense $prevWinLicense -prevOfficeLicense $prevOfficeLicense -prevOfficeDetail $prevOfficeDetail -ad $ad
        if ($rec) {
            $script:rescuedEndpoints[$pc.ToUpper()] = $cand
            return $rec
        }
    }

    # Stage 4: Remote Registry over SMB Port 445
    foreach ($cand in $orderedTargets) {
        $rec = Get-HardwareFromRemoteRegistry -targetAddress $cand -expectedHost $pc `
            -prevWinLicense $prevWinLicense -prevOfficeLicense $prevOfficeLicense -prevOfficeDetail $prevOfficeDetail -ad $ad
        if ($rec) {
            $script:rescuedEndpoints[$pc.ToUpper()] = $cand
            return $rec
        }
    }

    # Stage 5: Extended Timeout DCOM on AD FQDN
    if ($ad.AD_DNSHostName) {
        try {
            $opt = New-CimSessionOption -Protocol Dcom
            $s = New-CimSession -ComputerName $ad.AD_DNSHostName -SessionOption $opt -OperationTimeoutSec 20 -ErrorAction Stop
            $cs = Get-CimInstance Win32_ComputerSystem -CimSession $s -OperationTimeoutSec 15 -ErrorAction Stop
            if ($cs -and $cs.Name -and ($cs.Name -ieq $shortName)) {
                $rec = Get-HardwareFromCimSession -s $s -pcTarget $ad.AD_DNSHostName -isLocal $false `
                    -prevWinLicense $prevWinLicense -prevOfficeLicense $prevOfficeLicense -prevOfficeDetail $prevOfficeDetail `
                    -ad $ad -methodName '⚡ FQDN-DCOM' -statusDetail "Rescued via Extended DCOM on FQDN ($($ad.AD_DNSHostName))"
                Remove-CimSession $s -ErrorAction SilentlyContinue
                if ($rec) {
                    $script:rescuedEndpoints[$pc.ToUpper()] = $ad.AD_DNSHostName
                    return $rec
                }
            } else {
                Remove-CimSession $s -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # Diagnostic Stage 6: VNC Port 5900 Reachability Detection
    $vncLive = $false
    $vncTarget = $null
    foreach ($cand in $orderedTargets) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($cand, 5900, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(600, $false) -and $tcp.Connected) {
                $tcp.EndConnect($ar)
                $tcp.Close()
                $vncLive = $true
                $vncTarget = $cand
                break
            }
            $tcp.Close()
        } catch {}
    }

    if ($vncLive) {
        $ip = if ($vncTarget -match '^\d+\.\d+\.\d+\.\d+$') { $vncTarget } else { '' }
        $mac = ''
        if ($ip) {
            try {
                $arpOut = & arp.exe -a $ip 2>$null
                if ($arpOut -match '([0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2})') {
                    $mac = $Matches[1].ToUpper()
                }
            } catch {}
        }
        $prevCount = if ($oldRecord -and $oldRecord.Scan_Count) { [int]$oldRecord.Scan_Count } else { 0 }
        return (New-HardwareRecord @{
            PCName         = if ($oldRecord -and $oldRecord.PCName -and $oldRecord.PCName -ne '-') { $oldRecord.PCName } else { $pc }
            Status         = 'Online'
            Method         = '⚡ VNC:5900'
            Status_Detail  = "Online (VNC:5900 Active on $vncTarget) - Windows Management Ports (WMI/WinRM) blocked by Firewall"
            Fail_Count     = 0
            IP             = if ($ip) { $ip } else { if ($oldRecord -and $oldRecord.IP) { $oldRecord.IP } else { '' } }
            MAC            = if ($mac) { $mac } else { if ($oldRecord -and $oldRecord.MAC) { $oldRecord.MAC } else { '' } }
            Maker          = if ($oldRecord -and $oldRecord.Maker) { $oldRecord.Maker } else { '-' }
            Model          = if ($oldRecord -and $oldRecord.Model) { $oldRecord.Model } else { '-' }
            Serial         = if ($oldRecord -and $oldRecord.Serial) { $oldRecord.Serial } else { '-' }
            CPU            = if ($oldRecord -and $oldRecord.CPU) { $oldRecord.CPU } else { '-' }
            RAM_GB         = if ($oldRecord -and $oldRecord.RAM_GB) { $oldRecord.RAM_GB } else { '-' }
            Disk_Info      = if ($oldRecord -and $oldRecord.Disk_Info) { $oldRecord.Disk_Info } else { '-' }
            Win_License    = $prevWinLicense
            Office_License = $prevOfficeLicense
            Office_Detail  = $prevOfficeDetail
            AD_LastLogon   = if ($ad) { $ad.AD_LastLogon } else { '-' }
            AD_OU          = if ($ad) { $ad.AD_OU } else { '-' }
            Scan_Count     = ($prevCount + 1)
            First_Seen     = if ($oldRecord -and $oldRecord.First_Seen -and $oldRecord.First_Seen -ne '-') { $oldRecord.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
            Last_Scan      = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        })
    }

    return $null
}

# ================= 2) Hardware Scan (2-Pass: Fast Pass 1 -> Deep Penetration Pass 2) =================
if (-not $SkipHardware) {
    Write-Host '[STEP:2] Hardware Scan (Fast Pass 1 -> Deep Penetration Pass 2)...' -ForegroundColor Cyan
    Write-Host '--- Hardware scan ---'

    # Pre-load Master Database to track Fail_Count & preserve previous license/specs
    $masterDict = [ordered]@{}
    if (Test-Path -LiteralPath $MasterFile) {
        try {
            $oldMaster = @(Import-Csv -LiteralPath $MasterFile -Encoding UTF8)
            foreach ($row in $oldMaster) {
                if ($row.PCName) {
                    $masterDict[$row.PCName.ToUpper()] = New-HardwareRecord $row
                }
            }
        } catch {
            Write-Warning "Could not parse existing Master file: $($_.Exception.Message)"
        }
    }

    $stubbornQueue = [System.Collections.Generic.List[hashtable]]::new()
    $i = 0
    $hw = @(foreach ($pc in $pcs) {
        $i++
        Write-Progress -Activity 'Hardware scan' -Status "$pc ($i/$($pcs.Count))" -PercentComplete (10 + [math]::Round(55 * $i / $pcs.Count))
        Write-Host "[STAGE:HW|$i|$($pcs.Count)] Scanning $pc ($i/$($pcs.Count))..."

        $key = $pc.ToUpper()
        $shortKey = ($key -split '\.')[0]
        $prevFailCount = 0
        $prevWinLicense = '-'
        $prevOfficeLicense = '-'
        $prevOfficeDetail = '-'
        $oldRecord = $null

        if ($masterDict.Contains($key)) {
            $oldRecord = $masterDict[$key]
        } elseif ($masterDict.Contains($shortKey)) {
            $oldRecord = $masterDict[$shortKey]
        } else {
            foreach ($mVal in $masterDict.Values) {
                if ($mVal.IP -and ($mVal.IP -split ',\s*') -contains $pc) {
                    $oldRecord = $mVal
                    break
                }
            }
        }

        if ($oldRecord) {
            if ($oldRecord.Fail_Count) { [int]::TryParse([string]$oldRecord.Fail_Count, [ref]$prevFailCount) | Out-Null }
            if ($oldRecord.Win_License -and $oldRecord.Win_License -ne '-') { $prevWinLicense = $oldRecord.Win_License }
            if ($oldRecord.Office_License -and $oldRecord.Office_License -notin @('-', 'None')) { $prevOfficeLicense = $oldRecord.Office_License }
            if ($oldRecord.Office_Detail -and $oldRecord.Office_Detail -notin @('-', 'No Microsoft Office installation detected')) { $prevOfficeDetail = $oldRecord.Office_Detail }
        }

        if ($ThreadDelayMs -gt 0 -and $i -gt 1) {
            Start-Sleep -Milliseconds $ThreadDelayMs
        }

        if (-not (Test-PCConnection $pc)) {
            $ad = Get-ADInfo $pc
            $newFail = $prevFailCount + 1
            $statusDetailMsg = if ($script:lastConnInfo -and $script:lastConnInfo.Detail) { $script:lastConnInfo.Detail } else { 'Host unreachable (ping/ports timed out)' }
            $hData = @{
                PCName         = if ($oldRecord -and $oldRecord.PCName -and $oldRecord.PCName -ne '-') { $oldRecord.PCName } else { $pc }
                Status         = 'Offline'
                Method         = if ($script:lastConnInfo -and $script:lastConnInfo.Method) { $script:lastConnInfo.Method } else { 'Offline' }
                Status_Detail  = $statusDetailMsg
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
            $stubbornQueue.Add(@{
                PC         = $pc
                OldRecord  = $oldRecord
                Reason     = 'Offline'
                PrevFail   = $prevFailCount
                WinLic     = $prevWinLicense
                OffLic     = $prevOfficeLicense
                OffDet     = $prevOfficeDetail
                AD         = $ad
            })
            $itemOffline
            continue
        }

        try {
            $isLocal = ($pc -eq $env:COMPUTERNAME -or $pc -eq 'localhost' -or $pc -eq '127.0.0.1')
            $s = $null
            if (-not $isLocal) {
                $opt = New-CimSessionOption -Protocol Dcom
                $s = New-CimSession -ComputerName $pc -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop
            }

            $ad = Get-ADInfo $pc
            $connMethod = if ($script:lastConnInfo -and $script:lastConnInfo.Method) { $script:lastConnInfo.Method } else { 'DCOM' }
            $rec = Get-HardwareFromCimSession -s $s -pcTarget $pc -isLocal $isLocal `
                -prevWinLicense $prevWinLicense -prevOfficeLicense $prevOfficeLicense -prevOfficeDetail $prevOfficeDetail `
                -ad $ad -methodName $connMethod `
                -statusDetail 'Hardware scan completed successfully' -skipServerCheck $SkipServers

            if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue }

            if ($rec -and $rec.SkipServer) {
                continue
            }
            if ($rec) {
                Write-Host ('[LIVE_PC] ' + ($rec | ConvertTo-Json -Compress))
                $rec
            } else {
                throw "CIM instance retrieval failed"
            }
        }
        catch {
            if ($s) { Remove-CimSession $s -ErrorAction SilentlyContinue }
            $ad = Get-ADInfo $pc
            $newFail = $prevFailCount + 1
            $hDataErr = @{
                PCName         = if ($oldRecord -and $oldRecord.PCName -and $oldRecord.PCName -ne '-') { $oldRecord.PCName } else { $pc }
                Status         = "Error"
                Method         = if ($script:lastConnInfo -and $script:lastConnInfo.Method) { $script:lastConnInfo.Method } else { 'Error' }
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
            $stubbornQueue.Add(@{
                PC         = $pc
                OldRecord  = $oldRecord
                Reason     = 'Error'
                PrevFail   = $prevFailCount
                WinLic     = $prevWinLicense
                OffLic     = $prevOfficeLicense
                OffDet     = $prevOfficeDetail
                ErrorMsg   = $_.Exception.Message
                AD         = $ad
            })
            $itemErr
        }
    })
    Write-Progress -Activity 'Hardware scan' -Completed

    # ================= Pass 2: Automatic Deep Penetration ("Heavy Mode") =================
    if ($stubbornQueue.Count -gt 0) {
        Write-Host ""
        Write-Host "[STEP:2.5] Pass 2: Automatic Deep Penetration Scan ('Heavy Mode') for $($stubbornQueue.Count) stubborn hosts..." -ForegroundColor Magenta
        Write-Host "Flushing local DNS resolver cache (ipconfig /flushdns)..." -ForegroundColor Cyan
        try { ipconfig /flushdns | Out-Null } catch {}

        $sIdx = 0
        foreach ($stub in $stubbornQueue) {
            $sIdx++
            $sPc = $stub.PC
            Write-Host "[STAGE:DEEP|$sIdx|$($stubbornQueue.Count)] Deep probing stubborn host: $sPc ($sIdx/$($stubbornQueue.Count))..." -ForegroundColor Magenta

            # Live UI indicator: ⚡ Deep Scan
            $deepIndicator = New-HardwareRecord @{
                PCName        = $sPc
                Status        = 'Deep Scanning'
                Method        = '⚡ Probing'
                Status_Detail = 'Executing 5-stage penetration chain...'
                Fail_Count    = $stub.PrevFail
            }
            Write-Host ('[LIVE_PC] ' + ($deepIndicator | ConvertTo-Json -Compress))

            $stubAd = if ($stub.AD) { $stub.AD } else { Get-ADInfo $sPc }
            $rescued = Invoke-DeepPenetrationScan `
                -pc $sPc `
                -ad $stubAd `
                -oldRecord $stub.OldRecord `
                -prevFailCount $stub.PrevFail `
                -prevWinLicense $stub.WinLic `
                -prevOfficeLicense $stub.OffLic `
                -prevOfficeDetail $stub.OffDet `
                -masterDict $masterDict `
                -wasError ($stub.Reason -eq 'Error') `
                -healDns $AutoHealDns

            if ($rescued -and ($rescued.Status -eq 'OK' -or $rescued.Status -eq 'Online')) {
                if ($rescued.Status -eq 'OK') {
                    Write-Host "  [RESCUED] $sPc penetrated successfully! Method: $($rescued.Method)" -ForegroundColor Green
                } else {
                    Write-Host "  [DETECTED] $sPc live via $($rescued.Method)! ($($rescued.Status_Detail))" -ForegroundColor Yellow
                }
                for ($k = 0; $k -lt $hw.Count; $k++) {
                    if ($hw[$k].PCName -ieq $sPc) {
                        $hw[$k] = $rescued
                        break
                    }
                }
                $masterDict[$sPc.ToUpper()] = $rescued
                Write-Host ('[LIVE_PC] ' + ($rescued | ConvertTo-Json -Compress))
            } else {
                Write-Host "  [OFFLINE] $sPc confirmed offline or unreachable." -ForegroundColor Gray
                $finalOff = New-HardwareRecord @{
                    PCName        = $sPc
                    Status        = 'Offline'
                    Method        = 'Offline'
                    Status_Detail = if ($stub.Reason -eq 'Error') { "Error: $($stub.ErrorMsg) (Deep probe exhausted)" } else { 'Host unreachable (confirmed powered off or offline)' }
                    Fail_Count    = ($stub.PrevFail + 1)
                    Win_License   = $stub.WinLic
                    Office_License= $stub.OffLic
                    Office_Detail = $stub.OffDet
                    AD_LastLogon  = if ($stub.AD) { $stub.AD.AD_LastLogon } else { '-' }
                    AD_OU         = if ($stub.AD) { $stub.AD.AD_OU } else { '-' }
                }
                if ($stub.OldRecord -and ($stub.OldRecord.Status -eq 'OK' -or $stub.OldRecord.CPU)) {
                    $finalOff.Maker       = $stub.OldRecord.Maker
                    $finalOff.Model       = $stub.OldRecord.Model
                    $finalOff.Serial      = $stub.OldRecord.Serial
                    $finalOff.CPU         = $stub.OldRecord.CPU
                    $finalOff.Cores       = $stub.OldRecord.Cores
                    $finalOff.RAM_GB      = $stub.OldRecord.RAM_GB
                    $finalOff.Disk_C_Free = $stub.OldRecord.Disk_C_Free
                    $finalOff.Disks       = $stub.OldRecord.Disks
                    $finalOff.GPU         = $stub.OldRecord.GPU
                    $finalOff.OS          = $stub.OldRecord.OS
                    $finalOff.OSBuild     = $stub.OldRecord.OSBuild
                    $finalOff.IP          = $stub.OldRecord.IP
                    $finalOff.User        = $stub.OldRecord.User
                }
                for ($k = 0; $k -lt $hw.Count; $k++) {
                    if ($hw[$k].PCName -ieq $sPc) {
                        $hw[$k] = $finalOff
                        break
                    }
                }
                $masterDict[$sPc.ToUpper()] = $finalOff
                Write-Host ('[LIVE_PC] ' + ($finalOff | ConvertTo-Json -Compress))
            }
        }
    }


    # --- Master Database Synchronization ---
    if ($MasterMode) {
        foreach ($r in $hw) {
            $key = $r.PCName.ToUpper()
            if ($r.Status -eq 'OK') {
                if ($masterDict.Contains($key)) {
                    $old = $masterDict[$key]
                    $prevCount = 0
                    if ($old.Scan_Count) { [int]::TryParse([string]$old.Scan_Count, [ref]$prevCount) | Out-Null }
                    $r.Scan_Count = [string]($prevCount + 1)
                    $r.First_Seen = if ($old.First_Seen -and $old.First_Seen -ne '-') { $old.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                    $r.Last_Scan  = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Fail_Count = 0
                    if ((-not $r.Method -or $r.Method -eq '-') -and ($old.Method -and $old.Method -ne '-')) {
                        $r.Method = $old.Method
                    }
                    if ((-not $r.Win_License -or $r.Win_License -eq '-') -and ($old.Win_License -and $old.Win_License -ne '-')) {
                        $r.Win_License = $old.Win_License
                    }
                    if ((-not $r.Office_License -or $r.Office_License -in @('-', 'None')) -and ($old.Office_License -and $old.Office_License -notin @('-', 'None'))) {
                        $r.Office_License = $old.Office_License
                        $r.Office_Detail  = if ($old.Office_Detail -and $old.Office_Detail -ne '-') { $old.Office_Detail } else { $old.Office_License }
                    }
                } else {
                    $r.Scan_Count = '1'
                    $r.First_Seen = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Last_Scan  = Get-Date -Format 'yyyy-MM-dd HH:mm'
                    $r.Fail_Count = 0
                }
                $masterDict[$key] = New-HardwareRecord $r
            } else {
                # Host is Offline or Error
                if ($masterDict.Contains($key)) {
                    $old = $masterDict[$key]
                    $prevCount = if ($old.Scan_Count) { $old.Scan_Count } else { '0' }
                    $firstSeen = if ($old.First_Seen -and $old.First_Seen -ne '-') { $old.First_Seen } else { (Get-Date -Format 'yyyy-MM-dd HH:mm') }
                    $hMerged = @{
                        PCName         = $r.PCName
                        Status         = if ($old.Status -eq 'OK' -or ($old.CPU -and $old.CPU -ne '-')) { "Offline (Was OK)" } else { $r.Status }
                        Method         = if ($r.Method -and $r.Method -ne '-') { $r.Method } else { $old.Method }
                        Status_Detail  = $r.Status_Detail
                        Fail_Count     = $r.Fail_Count
                        Win_License    = if ($r.Win_License -and $r.Win_License -ne '-') { $r.Win_License } else { $old.Win_License }
                        Office_License = if ($r.Office_License -and $r.Office_License -notin @('-', 'None')) { $r.Office_License } else { $old.Office_License }
                        Office_Detail  = if ($r.Office_Detail -and $r.Office_Detail -notin @('-', 'No Microsoft Office installation detected')) { $r.Office_Detail } else { $old.Office_Detail }
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
                    $masterDict[$key] = New-HardwareRecord $r
                }
            }
        }

        # Save Master CSV with standardized columns across all records
        $masterRows = @($masterDict.Values | ForEach-Object { New-HardwareRecord $_ } | Sort-Object PCName)
        $masterRows | Export-Csv $MasterFile -NoTypeInformation -Encoding UTF8
        Write-Host "Master Database updated: $($masterRows.Count) total records -> $MasterFile" -ForegroundColor Cyan
    }

    # Snapshot CSV for this specific run
    $fHw = Join-Path $OutDir "Hardware_$stamp.csv"
    @($hw | ForEach-Object { New-HardwareRecord $_ }) | Export-Csv $fHw -NoTypeInformation -Encoding UTF8
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
        $swTargets = @($(foreach ($p in $pcs) { if ($script:rescuedEndpoints -and $script:rescuedEndpoints.ContainsKey($p.ToUpper())) { $script:rescuedEndpoints[$p.ToUpper()] } else { $p } }) | Select-Object -Unique)
        $rows = @(Invoke-Command -ComputerName $swTargets -ScriptBlock $remoteBlock `
                -ArgumentList $IncludeUserInstalls.IsPresent, $IncludeHidden.IsPresent `
                -ThrottleLimit $Throttle -ErrorAction SilentlyContinue -ErrorVariable winrmErr)
    }

    $all = New-Object System.Collections.Generic.List[object]
    $status = New-Object System.Collections.Generic.List[object]

    # Map IP endpoints back to original PC names if rescued via IP
    $reverseRescued = @{}
    if ($script:rescuedEndpoints) {
        foreach ($origHost in $script:rescuedEndpoints.Keys) {
            $rescuedTarget = $script:rescuedEndpoints[$origHost]
            $reverseRescued[$rescuedTarget.ToUpper()] = $origHost
        }
    }

    foreach ($g in ($rows | Group-Object PSComputerName)) {
        $canonicalHost = $g.Name
        if ($reverseRescued.ContainsKey($canonicalHost.ToUpper())) {
            $canonicalHost = $reverseRescued[$canonicalHost.ToUpper()]
        }
        foreach ($r in $g.Group) {
            $all.Add([pscustomobject]@{
                    PCName = $canonicalHost; Name = $r.Name; Version = $r.Version; Publisher = $r.Publisher
                    InstallDate = $r.InstallDate; InstallLocation = $r.InstallLocation; SizeMB = $r.SizeMB
                    Arch = $r.Arch; Scope = $r.Scope; RegistryKey = $r.RegistryKey
                })
        }
        $status.Add([pscustomobject]@{ PCName = $canonicalHost; Status = 'OK-WinRM'; Count = $g.Count })
    }

    $okSet = @($all | ForEach-Object { $_.PCName } | Select-Object -Unique)
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
            $dcomTarget = if ($script:rescuedEndpoints -and $script:rescuedEndpoints.ContainsKey($pc.ToUpper())) { $script:rescuedEndpoints[$pc.ToUpper()] } else { $pc }
            if (-not (Test-PCConnection $dcomTarget)) {
                $status.Add([pscustomobject]@{ PCName = $pc; Status = 'Offline'; Count = 0 })
                continue
            }
            try {
                $res = @(Get-SoftwareDcom -pc $dcomTarget -IncludeUser $IncludeUserInstalls.IsPresent -IncludeHidden $IncludeHidden.IsPresent)
                foreach ($r in $res) {
                    $r.PCName = $pc
                    $all.Add($r)
                }
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
    $hwBackfilled = $false
    $perPc = foreach ($g in ($final | Group-Object PCName)) {
        $keyApps = @($g.Group | Where-Object { $_.Name -match 'Office|Microsoft 365|Google Chrome|Firefox|Adobe|7-Zip|CrowdStrike|Antivirus|Defender|AnyDesk|TeamViewer' } | Select-Object -ExpandProperty Name -First 4)
        $topApps = if ($keyApps.Count -gt 0) { $keyApps -join ', ' } else { (($g.Group | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ') }
        $methodUsed = @($status | Where-Object { $_.PCName -ieq $g.Name } | Select-Object -ExpandProperty Status -First 1)
        if (-not $methodUsed) { $methodUsed = 'OK' }

        # Backfill Office_License into Hardware & Master records if WMI SoftwareLicensingProduct missed it
        $offSwApp = $g.Group | Where-Object { $_.Name -match '(?i)^(Microsoft 365|Microsoft Office (Professional|Standard|Home|Business|Enterprise|LTSC|365|20\d{2}))' -and $_.Name -notmatch '(?i)MUI|Proof|Shared|Component|Viewer|Redistributable|Visio|Project|Connector' } | Select-Object -First 1
        if ($offSwApp -and (-not $SkipHardware)) {
            $parsedSwOff = Parse-OfficeLicenseInfo $offSwApp.Name @()
            if ($parsedSwOff.Badge -notin @('-', 'None')) {
                $pcKeyUpper = $g.Name.ToUpper()
                if ($hw) {
                    foreach ($hItem in $hw) {
                        if ($hItem.PCName -ieq $g.Name -and ($hItem.Office_License -in @('-', 'None') -or [string]::IsNullOrWhiteSpace($hItem.Office_License))) {
                            $hItem.Office_License = $parsedSwOff.Badge
                            $hItem.Office_Detail  = $parsedSwOff.Detail
                            Write-Host ('[LIVE_PC] ' + ($hItem | ConvertTo-Json -Compress))
                            $hwBackfilled = $true
                        }
                    }
                }
                if ($MasterMode -and $masterDict -and $masterDict.Contains($pcKeyUpper)) {
                    $mEntry = $masterDict[$pcKeyUpper]
                    if ($mEntry.Office_License -in @('-', 'None') -or [string]::IsNullOrWhiteSpace($mEntry.Office_License)) {
                        $mEntry.Office_License = $parsedSwOff.Badge
                        $mEntry.Office_Detail  = $parsedSwOff.Detail
                        $masterDict[$pcKeyUpper] = New-HardwareRecord $mEntry
                        $hwBackfilled = $true
                    }
                }
            }
        }

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
    if ($hwBackfilled -and (-not $SkipHardware)) {
        if ($fHw -and $hw) {
            @($hw | ForEach-Object { New-HardwareRecord $_ }) | Export-Csv $fHw -NoTypeInformation -Encoding UTF8
        }
        if ($MasterMode -and $MasterFile -and $masterDict -and $masterDict.Count -gt 0) {
            @($masterDict.Values | ForEach-Object { New-HardwareRecord $_ } | Sort-Object PCName) | Export-Csv $MasterFile -NoTypeInformation -Encoding UTF8
        }
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

