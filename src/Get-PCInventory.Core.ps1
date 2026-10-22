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
    [int]$DaysActive = 30,           # only PCs that logged on to the domain within N days (AD mode)
    [int]$Throttle = 20,
    [string]$OutDir = 'C:\Inventory',
    [switch]$FallbackToAD            # If ComputerListFile is empty, fallback to AD if set
)

$Software = -not $NoSoftware

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'

$fHw = $null
$fByPC = $null
$fSoft = $null

# ================= 1) Computer list (works without RSAT) =================
$useAD = -not $ComputerListFile
if ($ComputerListFile) {
    if (-not (Test-Path $ComputerListFile)) {
        Write-Warning "List file not found: $ComputerListFile"
        return [pscustomobject]@{ Status = 'Error'; Message = "List file not found: $ComputerListFile" }
    }
    $pcs = @(Get-Content $ComputerListFile | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' } | ForEach-Object { $_.Trim() })
    if ($pcs.Count -eq 0) {
        Write-Warning "List file is empty: $ComputerListFile"
        if ($FallbackToAD) {
            $useAD = $true
        } else {
            Write-Host 'Cancelled.'
            return [pscustomobject]@{ Status = 'Cancelled'; Message = 'List file is empty and FallbackToAD was not requested.' }
        }
    }
}
if ($useAD) {
    $ft = (Get-Date).AddDays(-$DaysActive).ToFileTime()
    $ds = [adsisearcher]"(&(objectCategory=computer)(operatingSystem=*Windows*)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(lastLogonTimestamp>=$ft))"
    $ds.PageSize = 1000
    [void]$ds.PropertiesToLoad.Add('name')
    $pcs = $ds.FindAll() | ForEach-Object { $_.Properties['name'][0] } | Sort-Object
}
Write-Host "Computers to scan: $($pcs.Count)"
if ($pcs.Count -eq 0) {
    Write-Warning 'No computers found. Nothing to scan.'
    return [pscustomobject]@{ Status = 'Empty'; Message = 'No computers found.' }
}

# ================= 2) Hardware (original method: CIM over DCOM) =================
if (-not $SkipHardware) {
    Write-Host '--- Hardware scan ---'
    $i = 0
    $hw = foreach ($pc in $pcs) {
        $i++
        Write-Progress -Activity 'Hardware scan' -Status "$pc ($i/$($pcs.Count))" -PercentComplete (100 * $i / $pcs.Count)

        if (-not (Test-Connection $pc -Count 1 -Quiet)) {
            [pscustomobject]@{ PCName = $pc; Status = 'Offline' }
            continue
        }
        try {
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

            [pscustomobject]@{
                PCName   = $cs.Name
                Status   = 'OK'
                User     = $cs.UserName
                Maker    = $cs.Manufacturer
                Model    = $cs.Model
                Serial   = $bios.SerialNumber
                CPU      = $cpu.Name
                Cores    = $cpu.NumberOfCores
                RAM_GB   = [math]::Round(($ram | Measure-Object Capacity -Sum).Sum / 1GB)
                Disks    = ($disk | ForEach-Object { "$($_.Model) $([math]::Round($_.Size/1GB))GB" }) -join '; '
                GPU      = ($gpu.Name) -join '; '
                OS       = $os.Caption
                OSBuild  = $os.BuildNumber
                IP       = ($net.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '
                MAC      = ($net.MACAddress) -join ', '
                Scanned  = Get-Date -Format 'yyyy-MM-dd HH:mm'
            }
            Remove-CimSession $s
        }
        catch {
            [pscustomobject]@{ PCName = $pc; Status = "Error: $($_.Exception.Message)" }
        }
    }
    Write-Progress -Activity 'Hardware scan' -Completed

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

    Write-Host 'Method A: WinRM ...'
    $winrmErr = @()
    $rows = @(Invoke-Command -ComputerName $pcs -ScriptBlock $remoteBlock `
            -ArgumentList $IncludeUserInstalls.IsPresent, $IncludeHidden.IsPresent `
            -ThrottleLimit $Throttle -ErrorAction SilentlyContinue -ErrorVariable winrmErr)

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
            if (-not (Test-Connection $pc -Count 1 -Quiet)) {
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
    SoftwareHtml = if ($Software) { $fByPC } else { $null }
    SoftwareCsv  = if ($Software) { $fSoft } else { $null }
    Timestamp    = $stamp
}
