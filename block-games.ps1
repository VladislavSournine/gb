<#
.SYNOPSIS
    Blocks game websites on a Windows PC via the hosts file and keeps the block up to date.

.DESCRIPTION
    Downloads plain-text domain lists (by default: the UT1 "games" blacklist
    plus custom-block.txt from the same GitHub repo), writes every domain
    (plus its www. variant) to the hosts file as 0.0.0.0, and disables
    DNS-over-HTTPS in Chrome / Edge / Firefox so browsers cannot bypass hosts.

    A normal run also installs the scheduled task "GameBlock", which re-runs the
    LATEST version of this script from GitHub at every Windows startup and once
    a day. So edits to custom-block.txt or to this script reach every PC by itself.

    The blocked entries live between two marker lines, so re-running replaces
    the old block, and -Remove deletes it cleanly. Anything else in hosts is
    never touched. If a download fails (e.g. no network yet), hosts is left as is.

.PARAMETER ListUrl
    One or more URLs of plain-text lists, one domain per line. Lines starting with # are ignored.

.PARAMETER Extra
    Additional domains to block on top of the lists, e.g. -Extra roblox.com,epicgames.com

.PARAMETER Remove
    Remove the block, the scheduled task and the browser DNS-over-HTTPS policies.

.PARAMETER NoAutoUpdate
    Block once, do not install (or remove an existing) scheduled task.

.PARAMETER FromTask
    Used by the scheduled task itself: skip task installation, retry downloads
    while the network comes up, write a log to C:\ProgramData\GameBlock\last-run.log.

.PARAMETER NoWww
    Do not add www. variants (halves the hosts file size).

.PARAMETER SkipBrowserPolicy
    Do not touch browser DNS-over-HTTPS policies.

.EXAMPLE
    # Install on a school PC (PowerShell as Administrator):
    irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1 | iex

.EXAMPLE
    # With parameters:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1))) -Remove
#>
[CmdletBinding()]
param(
    [string[]] $ListUrl   = @(
        'https://raw.githubusercontent.com/olbat/ut1-blacklists/master/blacklists/games/domains',
        'https://raw.githubusercontent.com/VladislavSournine/gb/main/custom-block.txt'
    ),
    [string[]] $Extra     = @(),
    [switch]   $Remove,
    [switch]   $NoAutoUpdate,
    [switch]   $FromTask,
    [switch]   $NoWww,
    [switch]   $SkipBrowserPolicy,
    [string]   $HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$ScriptUrl   = 'https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1'
$TaskName    = 'GameBlock'
$LogDir      = "$env:ProgramData\GameBlock"
$MarkerBegin = '# >>> GAME-BLOCK BEGIN (managed by block-games.ps1, do not edit) >>>'
$MarkerEnd   = '# <<< GAME-BLOCK END <<<'
$MinExpectedDomains = 100   # sanity check: a broken download must not wipe the existing block

$CleanDomainRegex = [regex]'^(?=.{1,253}$)([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z0-9-]{2,63}$'
$IpRegex          = [regex]'^\d{1,3}(\.\d{1,3}){3}$'

function ConvertTo-CleanDomain {
    <# Normalizes one raw line into a bare domain, or returns $null if the line is not a blockable domain. #>
    param([string] $Line)
    if ($null -eq $Line) { return $null }
    $d = $Line.Trim().ToLowerInvariant()
    if ($d -eq '' -or $d.StartsWith('#')) { return $null }
    $d = $d -replace '\s+#.*$', ''              # trailing comment
    $d = $d -replace '^(0\.0\.0\.0|127\.0\.0\.1)\s+', ''   # already in hosts format
    $d = $d -replace '^[a-z]+://', ''           # scheme
    $d = $d -replace '[/:?].*$', ''             # path / port / query
    $d = $d.TrimEnd('.')
    if ($IpRegex.IsMatch($d)) { return $null }  # raw IPs can't be blocked via hosts
    if (-not $CleanDomainRegex.IsMatch($d)) { return $null }
    return $d
}

function Get-BlockEntries {
    <# Turns raw list lines into sorted, de-duplicated "0.0.0.0 domain" hosts lines.
       No pipelines on purpose: Windows PowerShell 5.1 is slow with them on ~70k items. #>
    param([string[]] $Lines, [switch] $NoWww)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $Lines) {
        # fast path: most lines are already clean lower-case domains
        if ($CleanDomainRegex.IsMatch($line) -and -not $IpRegex.IsMatch($line)) { $d = $line }
        else { $d = ConvertTo-CleanDomain $line; if (-not $d) { continue } }
        [void]$set.Add($d)
        if (-not $NoWww -and -not $d.StartsWith('www.')) { [void]$set.Add("www.$d") }
    }
    $sorted = [string[]]::new($set.Count)
    $set.CopyTo($sorted)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    for ($i = 0; $i -lt $sorted.Length; $i++) { $sorted[$i] = "0.0.0.0 " + $sorted[$i] }
    return ,$sorted
}

function Get-BlockSectionEntries {
    <# Returns the "0.0.0.0 ..." lines currently inside the managed section. #>
    param([string[]] $HostsLines)
    $out = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($l in $HostsLines) {
        if ($l -eq $MarkerBegin) { $inside = $true;  continue }
        if ($l -eq $MarkerEnd)   { $inside = $false; continue }
        if ($inside -and $l.StartsWith('0.0.0.0 ')) { $out.Add($l) }
    }
    return ,$out.ToArray()
}

function Test-SameEntries {
    param([string[]] $A, [string[]] $B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -cne $B[$i]) { return $false } }
    return $true
}

function Remove-BlockSection {
    <# Returns hosts content without the managed section (everything else is kept as-is). #>
    param([string[]] $HostsLines)
    $out = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($l in $HostsLines) {
        if ($l -eq $MarkerBegin) { $inside = $true;  continue }
        if ($l -eq $MarkerEnd)   { $inside = $false; continue }
        if (-not $inside) { $out.Add($l) }
    }
    # drop trailing blank lines left behind
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    return ,$out.ToArray()
}

function Add-BlockSection {
    param([string[]] $HostsLines, [string[]] $Entries, [string[]] $Source)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.AddRange([string[]](Remove-BlockSection $HostsLines))
    $out.Add(''); $out.Add($MarkerBegin)
    foreach ($s in $Source) { $out.Add("# source: $s") }
    $out.Add("# updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $out.AddRange($Entries)
    $out.Add($MarkerEnd)
    return ,$out.ToArray()
}

function Get-TaskCommand {
    <# The command the scheduled task runs: always fetches the latest script from GitHub. #>
    param([string] $Url)
    return "& ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing '$Url'))) -FromTask"
}

function Install-GameBlockTask {
    $cmd      = Get-TaskCommand $ScriptUrl
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`""
    $boot     = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT1M'                                   # give the network a minute
    $daily    = New-ScheduledTaskTrigger -Daily -At 7:40am  # for PCs that are never rebooted
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($boot, $daily) `
        -Settings $settings -Principal $principal -Description "Updates game-site block in hosts from $ScriptUrl" -Force | Out-Null
    Write-Host "Auto-update installed: task '$TaskName' runs at startup and daily at 7:40." -ForegroundColor Green
}

function Uninstall-GameBlockTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed."
    }
}

function Set-BrowserDohPolicy {
    <# Disables (or with -Restore, un-sets) DNS-over-HTTPS so browsers respect the hosts file. #>
    param([switch] $Restore)
    $policies = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome';             Name = 'DnsOverHttpsMode'; Value = 'off'; Type = 'String' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';            Name = 'DnsOverHttpsMode'; Value = 'off'; Type = 'String' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Enabled';      Value = 0;     Type = 'DWord'  },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Locked';       Value = 1;     Type = 'DWord'  }
    )
    foreach ($p in $policies) {
        if ($Restore) {
            Remove-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction SilentlyContinue
        } else {
            if (-not (Test-Path $p.Path)) { New-Item -Path $p.Path -Force | Out-Null }
            New-ItemProperty -Path $p.Path -Name $p.Name -Value $p.Value -PropertyType $p.Type -Force | Out-Null
        }
    }
}

function Write-HostsFile {
    param([string] $Path, [string[]] $Lines)
    $backup = "$Path.game-block.bak"
    if (-not (Test-Path $backup)) { Copy-Item $Path $backup -Force }   # keep the ORIGINAL hosts once
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllLines($tmp, $Lines, [System.Text.Encoding]::ASCII)
    Copy-Item $tmp $Path -Force
    Remove-Item $tmp -Force
}

function Get-ListText {
    <# Downloads one list; when run by the task, retries while the network comes up after boot. #>
    param([string] $Url, [int] $Attempts)
    for ($i = 1; ; $i++) {
        try { return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content }
        catch {
            if ($i -ge $Attempts) { throw }
            Write-Host "  download failed ($($_.Exception.Message)), retry $i/$($Attempts - 1) in 20 s..."
            Start-Sleep -Seconds 20
        }
    }
}

function Invoke-GameBlock {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run PowerShell as Administrator.' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest much slower in 5.1
    $current = @(Get-Content -Path $HostsPath -ErrorAction Stop)

    if ($Remove) {
        Uninstall-GameBlockTask
        Write-HostsFile -Path $HostsPath -Lines (Remove-BlockSection $current)
        if (-not $SkipBrowserPolicy) { Set-BrowserDohPolicy -Restore }
        ipconfig /flushdns | Out-Null
        Write-Host 'Game block removed.' -ForegroundColor Green
        return
    }

    $attempts = 1; if ($FromTask) { $attempts = 10 }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($url in $ListUrl) {
        Write-Host "Downloading list: $url"
        $lines.AddRange([string[]]((Get-ListText -Url $url -Attempts $attempts) -split "`r?`n"))
    }
    $lines.AddRange([string[]]$Extra)

    Write-Host 'Processing...'
    $entries = Get-BlockEntries -Lines $lines.ToArray() -NoWww:$NoWww
    if ($entries.Count -lt $MinExpectedDomains) {
        throw "Only $($entries.Count) domains parsed - list looks broken, hosts file left unchanged."
    }

    if (Test-SameEntries (Get-BlockSectionEntries $current) $entries) {
        Write-Host "Block list unchanged ($($entries.Count) host names), hosts not rewritten."
    } else {
        Write-HostsFile -Path $HostsPath -Lines (Add-BlockSection $current $entries $ListUrl)
        ipconfig /flushdns | Out-Null
        Write-Host "Blocked $($entries.Count) host names." -ForegroundColor Green
    }
    if (-not $SkipBrowserPolicy) { Set-BrowserDohPolicy }

    if ($FromTask)         { }                          # the task must not re-register itself
    elseif ($NoAutoUpdate) { Uninstall-GameBlockTask }
    else                   { Install-GameBlockTask }

    if (-not $FromTask) { Write-Host 'Done. Restart browsers to apply.' -ForegroundColor Green }
}

# Run unless dot-sourced (tests dot-source the file to load the functions only).
if ($MyInvocation.InvocationName -ne '.') {
    if ($FromTask) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Start-Transcript -Path "$LogDir\last-run.log" -Force | Out-Null
        try { Invoke-GameBlock } finally { Stop-Transcript | Out-Null }
    } else {
        Invoke-GameBlock
    }
}
