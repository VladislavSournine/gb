<#
.SYNOPSIS
    Blocks game websites on a Windows PC via the hosts file.

.DESCRIPTION
    Downloads plain-text domain lists (by default: the UT1 "games" blacklist
    plus custom-block.txt from the same GitHub repo),
    writes every domain (plus its www. variant) to the hosts file as 0.0.0.0,
    and disables DNS-over-HTTPS in Chrome / Edge / Firefox so browsers
    cannot bypass the hosts file.

    The blocked entries live between two marker lines, so running the script
    again replaces the old block (safe to re-run for updates), and -Remove
    deletes it cleanly. Anything else in hosts is never touched.

.PARAMETER ListUrl
    One or more URLs of plain-text lists, one domain per line. Lines starting with # are ignored.
    All lists are merged. If any list fails to download, the hosts file is left unchanged.

.PARAMETER Extra
    Additional domains to block on top of the list, e.g. -Extra roblox.com,epicgames.com

.PARAMETER Remove
    Remove the block and restore browser DNS-over-HTTPS settings.

.PARAMETER NoWww
    Do not add www. variants (halves the hosts file size).

.PARAMETER SkipBrowserPolicy
    Do not touch browser DNS-over-HTTPS policies.

.EXAMPLE
    # Run from the internet on a school PC (PowerShell as Administrator):
    irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1 | iex

.EXAMPLE
    # With parameters:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-games.ps1))) -Extra roblox.com
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
    [switch]   $NoWww,
    [switch]   $SkipBrowserPolicy,
    [string]   $HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$MarkerBegin = '# >>> GAME-BLOCK BEGIN (managed by block-games.ps1, do not edit) >>>'
$MarkerEnd   = '# <<< GAME-BLOCK END <<<'
$MinExpectedDomains = 100   # sanity check: a broken download must not wipe the existing block

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
    if ($d -match '^\d{1,3}(\.\d{1,3}){3}$') { return $null }   # raw IPs can't be blocked via hosts
    if ($d -notmatch '^(?=.{1,253}$)([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z0-9-]{2,63}$') { return $null }
    return $d
}

function Get-BlockEntries {
    <# Turns raw list lines into sorted, de-duplicated "0.0.0.0 domain" hosts lines. #>
    param([string[]] $Lines, [switch] $NoWww)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $Lines) {
        $d = ConvertTo-CleanDomain $line
        if (-not $d) { continue }
        [void]$set.Add($d)
        if (-not $NoWww -and -not $d.StartsWith('www.')) { [void]$set.Add("www.$d") }
    }
    return @($set | Sort-Object | ForEach-Object { "0.0.0.0 $_" })
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
    $base = Remove-BlockSection $HostsLines
    $header = @('', $MarkerBegin) + @($Source | ForEach-Object { "# source: $_" }) + "# updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    return ,@($base + $header + $Entries + $MarkerEnd)
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

function Invoke-GameBlock {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run PowerShell as Administrator.' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $current = @(Get-Content -Path $HostsPath -ErrorAction Stop)

    if ($Remove) {
        Write-HostsFile -Path $HostsPath -Lines (Remove-BlockSection $current)
        if (-not $SkipBrowserPolicy) { Set-BrowserDohPolicy -Restore }
        ipconfig /flushdns | Out-Null
        Write-Host 'Game block removed.' -ForegroundColor Green
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($url in $ListUrl) {
        Write-Host "Downloading list: $url"
        $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop).Content
        $lines.AddRange([string[]]($raw -split "`r?`n"))
    }
    $lines.AddRange([string[]]$Extra)
    $entries = Get-BlockEntries -Lines $lines -NoWww:$NoWww
    if ($entries.Count -lt $MinExpectedDomains) {
        throw "Only $($entries.Count) domains parsed - list looks broken, hosts file left unchanged."
    }

    Write-HostsFile -Path $HostsPath -Lines (Add-BlockSection $current $entries $ListUrl)
    if (-not $SkipBrowserPolicy) { Set-BrowserDohPolicy }
    ipconfig /flushdns | Out-Null
    Write-Host "Blocked $($entries.Count) host names. Restart browsers to apply." -ForegroundColor Green
}

# Run unless dot-sourced (tests dot-source the file to load the functions only).
if ($MyInvocation.InvocationName -ne '.') { Invoke-GameBlock }
