<#
.SYNOPSIS
    Blocks game websites on a Windows PC via the hosts file and keeps the block up to date.

.DESCRIPTION
    Downloads plain-text domain lists (by default: the UT1 "games" blacklist
    plus custom-block.txt from the same GitHub repo), writes every domain
    (plus its www. variant) to the hosts file as 0.0.0.0, and disables
    DNS-over-HTTPS in Chrome / Edge / Firefox so browsers cannot bypass hosts.
    Whole zones from block-tld.txt (.tv, .ru ...) are blocked with Windows DNS rules (NRPT),
    because hosts has no wildcards.

    A normal run also installs the scheduled task "GameBlock", which re-runs the
    LATEST version of this script from GitHub at every Windows startup and once
    a day. So edits to custom-block.txt or to this script reach every PC by itself.

    The blocked entries live between two marker lines, so re-running replaces
    the old block, and -Remove deletes it cleanly. Anything else in hosts is
    never touched. If a download fails (e.g. no network yet), hosts is left as is.

.PARAMETER ListUrl
    One or more URLs of plain-text lists, one domain per line. Lines starting with # are ignored.
    Default: UT1 categories games, audio-video (streams, video, music), vpn, social_networks, manga,
    plus custom-block.txt.

.PARAMETER AllowUrl
    URL of a list of domains that are never blocked, together with all their subdomains
    (default: allow-sites.txt from the repo, e.g. YouTube). Empty string = no exceptions.

.PARAMETER TldUrl
    URL of a list of whole zones to block (default: block-tld.txt from the repo).
    Empty string = remove the zone rules this script added.

.PARAMETER Extra
    Additional domains to block on top of the lists, e.g. -Extra roblox.com,epicgames.com

.PARAMETER Remove
    Remove the block, the zone rules, the scheduled task and the browser DNS-over-HTTPS policies.

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
        'https://raw.githubusercontent.com/olbat/ut1-blacklists/master/blacklists/audio-video/domains',
        'https://raw.githubusercontent.com/olbat/ut1-blacklists/master/blacklists/vpn/domains',
        'https://raw.githubusercontent.com/olbat/ut1-blacklists/master/blacklists/social_networks/domains',
        'https://raw.githubusercontent.com/olbat/ut1-blacklists/master/blacklists/manga/domains',
        'https://raw.githubusercontent.com/VladislavSournine/gb/main/custom-block.txt'
    ),
    [string]   $AllowUrl  = 'https://raw.githubusercontent.com/VladislavSournine/gb/main/allow-sites.txt',
    [string]   $TldUrl    = 'https://raw.githubusercontent.com/VladislavSournine/gb/main/block-tld.txt',
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
$TldSinkhole   = '192.0.2.1'   # TEST-NET: nothing answers there (see Set-TldBlock)
$TldComment    = 'GameBlock'   # tags our NRPT rules, so rules made by anyone else are never touched
$ProtectedTlds = @('com', 'net', 'org', 'ua', 'edu', 'gov')   # GitHub (auto-update) and Ukrainian sites must keep working

# second labels that make a 3-label name a bare site (friv.com.ua, bbc.co.uk): those still get a www. variant
$WwwSuffixLabels  = [System.Collections.Generic.HashSet[string]]::new([string[]]@('co', 'com', 'net', 'org', 'gov', 'edu', 'ac'))
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

function Test-Allowed {
    <# True when $Domain or any parent domain of it is in $AllowSet (m.youtube.com -> youtube.com). #>
    param([string] $Domain, [System.Collections.Generic.HashSet[string]] $AllowSet)
    $d = $Domain
    while ($true) {
        if ($AllowSet.Contains($d)) { return $true }
        $dot = $d.IndexOf('.'); if ($dot -lt 0) { return $false }
        $d = $d.Substring($dot + 1)
    }
}

function Get-BlockEntries {
    <# Turns raw list lines into sorted, de-duplicated "0.0.0.0 domain" hosts lines.
       www. is added only to bare sites (friv.com, friv.com.ua), not to m.tiktok.com or VPN node names: fewer names
       keep the Windows DNS Client fast. Domains in $SkipZones ('.ru', blocked by NRPT already) are left out.
       No pipelines on purpose: Windows PowerShell 5.1 is slow with them on ~70k items. #>
    param([string[]] $Lines, [string[]] $Allow = @(), [string[]] $SkipZones = @(), [switch] $NoWww)
    $allowSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($a in $Allow) { $c = ConvertTo-CleanDomain $a; if ($c) { [void]$allowSet.Add($c) } }
    $skipSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($SkipZones))
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $Lines) {
        # fast path: most lines are already clean lower-case domains
        if ($CleanDomainRegex.IsMatch($line) -and -not $IpRegex.IsMatch($line)) { $d = $line }
        else { $d = ConvertTo-CleanDomain $line; if (-not $d) { continue } }
        if ($allowSet.Count -and (Test-Allowed $d $allowSet)) { continue }
        if ($skipSet.Count -and $skipSet.Contains($d.Substring($d.LastIndexOf('.')))) { continue }
        [void]$set.Add($d)
        if ($NoWww -or $d.StartsWith('www.')) { continue }
        $p = $d.Split('.')
        if ($p.Length -eq 2 -or ($p.Length -eq 3 -and $WwwSuffixLabels.Contains($p[1]))) { [void]$set.Add("www.$d") }
    }
    $sorted = [string[]]::new($set.Count)
    $set.CopyTo($sorted)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    for ($i = 0; $i -lt $sorted.Length; $i++) { $sorted[$i] = "0.0.0.0 " + $sorted[$i] }
    return ,$sorted
}

function ConvertTo-TldNamespaces {
    <# Raw block-tld.txt lines -> sorted unique NRPT namespaces ('.tv'). Comments, junk and protected zones are skipped. #>
    param([string[]] $Lines)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        $t = ($line -replace '#.*$', '').Trim().ToLowerInvariant().TrimStart('.')
        if ($t -notmatch '^([a-z]{2,63}|xn--[a-z0-9-]{1,59})$') { continue }
        if ($ProtectedTlds -contains $t) { Write-Warning "Zone .$t is never blocked (skipped)."; continue }
        [void]$set.Add(".$t")
    }
    $sorted = [string[]]::new($set.Count)
    $set.CopyTo($sorted)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return ,$sorted
}

function Set-TldBlock {
    <# Makes our NRPT rules match $Namespaces: names in each zone are sent to 192.0.2.1 (TEST-NET, nothing answers there),
       so no site in the zone opens. Not 127.0.0.1: Windows lets any user listen on local port 53, so a student could
       run their own resolver there. An empty list removes our rules. Returns $true when rules changed.
       Does not flush the DNS cache: every flush makes Windows re-read the whole hosts file (minutes on slow PCs). #>
    param([string[]] $Namespaces)
    $ours = @(Get-DnsClientNrptRule | Where-Object { $_.Comment -eq $TldComment })
    # compare zone AND server, so rules made by an older version (127.0.0.1) get replaced too
    $have = [string[]]@($ours | ForEach-Object { "$($_.Namespace) > $($_.NameServers -join ',')" })
    $want = [string[]]@($Namespaces | ForEach-Object { "$_ > $TldSinkhole" })
    [Array]::Sort($have, [StringComparer]::Ordinal)
    [Array]::Sort($want, [StringComparer]::Ordinal)
    if (Test-SameEntries $have $want) { Write-Host "Blocked zones unchanged: $($Namespaces -join ' ')"; return $false }
    foreach ($r in $ours) { Remove-DnsClientNrptRule -Name $r.Name -Force | Out-Null }
    foreach ($ns in $Namespaces) { Add-DnsClientNrptRule -Namespace $ns -NameServers $TldSinkhole -Comment $TldComment | Out-Null }
    Write-Host "Blocked zones: $($Namespaces -join ' ')" -ForegroundColor Green
    return $true
}

function Test-TldBlockActive {
    <# True when every zone is in the EFFECTIVE NRPT policy with our server. Rules can exist and still be ignored:
       a domain Group Policy with its own NRPT rules overrides local ones. Only then may hosts leave the zones out. #>
    param([string[]] $Namespaces)
    $active = @(Get-DnsClientNrptPolicy | Where-Object { $_.NameServers -contains $TldSinkhole } | ForEach-Object { $_.Namespace })
    foreach ($ns in $Namespaces) { if ($active -notcontains $ns) { return $false } }
    return $true
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

function ConvertTo-HostsLines {
    <# "0.0.0.0 a" entries -> "0.0.0.0 a b c ..." lines, 9 names per line (the most Windows reads from one line).
       ~90k one-name lines make the Windows DNS Client service hang; 9x fewer lines block the same names. #>
    param([string[]] $Entries)
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Entries.Length; $i += 9) {
        $names = for ($j = $i; $j -lt [Math]::Min($i + 9, $Entries.Length); $j++) { $Entries[$j].Substring(8) }
        $out.Add('0.0.0.0 ' + ($names -join ' '))
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
    <# The command the scheduled task runs: always fetches the latest script from GitHub.
       PS 5.1 on some PCs doesn't offer TLS 1.2 by default and GitHub closes the connection. #>
    param([string] $Url)
    return "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing '$Url'))) -FromTask"
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
    # the DNS Client service locks hosts while it re-reads it (after a flush or NRPT change), on slow PCs for minutes
    try {
        for ($i = 1; ; $i++) {
            try { Copy-Item $tmp $Path -Force -ErrorAction Stop; break }
            catch [System.IO.IOException] {
                if ($i -ge 30) { throw "hosts is still locked after 60 s (DNS Client busy?), not changed: $($_.Exception.Message)" }
                if ($i -eq 1) { Write-Host "$(Get-Date -Format HH:mm:ss) hosts is busy (Windows is reading it), waiting..." }
                Start-Sleep -Seconds 2
            }
        }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
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

# --- secure folder: these three functions are kept IDENTICAL in block-apps.ps1 and block-games.ps1
#     (each script runs standalone via irm; tests/apps.tests.ps1 checks the copies match).
#     By default any user may create folders under ProgramData, so a student could pre-create ours,
#     plant files or swap it for a junction pointing elsewhere.

function New-LockedDirSecurity {
    <# Administrators + SYSTEM full control, nothing inherited from ProgramData, owner Administrators. #>
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    return $acl
}

function Test-TrustedOwner {
    <# True when an administrator owns the file/folder: Administrators, SYSTEM, the admin running now, or any member
       of the local Administrators group (Windows makes the teacher's own account the owner of what they create). #>
    param([string] $Path)
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -in @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) { return $true }
    # not available in 32-bit PowerShell, fails on groups with orphaned SIDs: then only the SIDs above count
    $admins = @(); try { $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.SID.Value }) } catch { }
    return ($admins -contains $owner)
}

function Initialize-SecureDir {
    <# Makes $Path a real folder owned by an administrator and locked to Administrators + SYSTEM.
       A link or a student-made folder is renamed aside (renaming never follows a link, nothing is deleted)
       and a fresh folder is created WITH the locked ACL, so there is no gap between create and lock.
       An administrator-owned folder cannot be renamed or deleted by a student, so it is safe to re-lock in place. #>
    param([string] $Path)
    $isLink = { ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
    $exists = $true; try { [void][IO.File]::GetAttributes($Path) } catch { $exists = $false }   # GetAttributes does not follow links
    if ($exists -and ((& $isLink) -or -not (Test-TrustedOwner $Path))) {
        $aside = "$Path.untrusted-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        [IO.Directory]::Move($Path, $aside)
        Write-Warning "$Path was not created by an administrator (or is a link): moved to $aside"
        $exists = $false
    }
    if ($exists) {
        Set-Acl -LiteralPath $Path -AclObject (New-LockedDirSecurity) -ErrorAction Stop
    } elseif ($PSVersionTable.PSEdition -eq 'Core') {
        [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Path), (New-LockedDirSecurity))
    } else {
        [void][IO.Directory]::CreateDirectory($Path, (New-LockedDirSecurity))
    }
    # final check: a student racing us (re-creating the folder or a link right after the rename) ends here
    if ((& $isLink) -or -not (Test-TrustedOwner $Path)) { throw "$Path could not be secured (link or not owned by an administrator)." }
}

function Initialize-LogDir {
    <# The task runs as SYSTEM and writes last-run.log here. After the folder is secured nobody but admins can add
       anything to it, but a file or link planted earlier may still sit at the log path: remove it without
       following it, and refuse to log if anything is still there. #>
    Initialize-SecureDir $LogDir
    $log = "$LogDir\last-run.log"
    $attr = $null; try { $attr = [IO.File]::GetAttributes($log) } catch { }
    if ($null -ne $attr) {
        # Directory.Delete (non-recursive) removes a junction itself; File.Delete removes a file or a file link
        if ($attr -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($log) } else { [IO.File]::Delete($log) }
    }
    $left = $true; try { [void][IO.File]::GetAttributes($log) } catch { $left = $false }
    if ($left) { throw "$log could not be removed." }
}

function Invoke-GameBlock {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run PowerShell as Administrator.' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest much slower in 5.1
    Write-Host "$(Get-Date -Format HH:mm:ss) Script downloaded, reading hosts file..."
    $current = @(Get-Content -Path $HostsPath -ErrorAction Stop)
    Write-Host "$(Get-Date -Format HH:mm:ss) hosts: $($current.Count) lines"

    if ($Remove) {
        Uninstall-GameBlockTask
        Write-HostsFile -Path $HostsPath -Lines (Remove-BlockSection $current)
        try { [void](Set-TldBlock @()) } catch { Write-Warning "Zone rules not removed: $($_.Exception.Message)" }
        if (-not $SkipBrowserPolicy) { Set-BrowserDohPolicy -Restore }
        ipconfig /flushdns | Out-Null
        Write-Host 'Game block removed.' -ForegroundColor Green
        return
    }

    $attempts = 1; if ($FromTask) { $attempts = 10 }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($url in $ListUrl) {
        Write-Host "$(Get-Date -Format HH:mm:ss) Downloading list: $url"
        $lines.AddRange([string[]]((Get-ListText -Url $url -Attempts $attempts) -split "`r?`n"))
    }
    $lines.AddRange([string[]]$Extra)
    $allow = @()
    if ($AllowUrl) {
        Write-Host "Downloading exceptions: $AllowUrl"
        $allow = (Get-ListText -Url $AllowUrl -Attempts $attempts) -split "`r?`n"
    }

    # zones first: hosts may leave out their domains only when the zone rules are really in place.
    # A failed download or missing DnsClient module must not undo any block: old rules stay, hosts keeps everything.
    $zones = @(); $flush = $false
    try {
        if ($TldUrl) {
            Write-Host "$(Get-Date -Format HH:mm:ss) Downloading blocked zones: $TldUrl"
            $zones = ConvertTo-TldNamespaces ((Get-ListText -Url $TldUrl -Attempts $attempts) -split "`r?`n")
        }
        $flush = Set-TldBlock $zones
        if ($zones.Count -and -not (Test-TldBlockActive $zones)) {
            $zones = @(); Write-Warning 'Zone rules are not in effect (Group Policy NRPT?): their sites stay in hosts.'
        }
    } catch { $zones = @(); Write-Warning "Zone block not updated: $($_.Exception.Message)" }

    Write-Host "$(Get-Date -Format HH:mm:ss) Processing..."
    $entries = Get-BlockEntries -Lines $lines.ToArray() -Allow $allow -SkipZones $zones -NoWww:$NoWww
    if ($entries.Count -lt $MinExpectedDomains) {
        throw "Only $($entries.Count) domains parsed - list looks broken, hosts file left unchanged."
    }

    $hostsLines = ConvertTo-HostsLines $entries
    if (Test-SameEntries (Get-BlockSectionEntries $current) $hostsLines) {
        Write-Host "Block list unchanged ($($entries.Count) host names), hosts not rewritten."
    } else {
        Write-HostsFile -Path $HostsPath -Lines (Add-BlockSection $current $hostsLines $ListUrl)
        $flush = $true
        Write-Host "Blocked $($entries.Count) host names." -ForegroundColor Green
    }
    if ($flush) {   # once per run: Windows re-reads the whole hosts file on every flush
        Write-Host "$(Get-Date -Format HH:mm:ss) Flushing DNS cache (Windows re-reads hosts, may take a while)..."
        ipconfig /flushdns | Out-Null
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
        # an unsafe log folder must not stop the block update itself: run without a log then
        $logOk = $true
        try { Initialize-LogDir } catch { $logOk = $false; Write-Warning "Log disabled: $($_.Exception.Message)" }
        if ($logOk) { Start-Transcript -Path "$LogDir\last-run.log" -Force | Out-Null }
        try { Invoke-GameBlock } finally { if ($logOk) { Stop-Transcript | Out-Null } }
    } else {
        Invoke-GameBlock
    }
}
