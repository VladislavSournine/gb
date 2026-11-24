# Dependency-free tests: pwsh ./tests/block-games.tests.ps1   (exit code 0 = all passed)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../block-games.ps1"   # dot-source: loads functions, does not run

$script:failed = 0
function Assert-Equal($Name, $Expected, $Actual) {
    $e = ($Expected | Out-String).Trim(); $a = ($Actual | Out-String).Trim()
    if ($e -ceq $a) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name`n  expected: $e`n  actual:   $a" -ForegroundColor Red; $script:failed++ }
}

# --- ConvertTo-CleanDomain ---
Assert-Equal 'plain domain'        'friv.com'          (ConvertTo-CleanDomain 'friv.com')
Assert-Equal 'trims + lowercases'  'friv.com'          (ConvertTo-CleanDomain '  FRIV.com  ')
Assert-Equal 'strips url parts'    'games.example.org' (ConvertTo-CleanDomain 'https://games.example.org:8080/play?x=1')
Assert-Equal 'strips hosts prefix' 'friv.com'          (ConvertTo-CleanDomain '0.0.0.0 friv.com')
Assert-Equal 'strips comment'      'friv.com'          (ConvertTo-CleanDomain 'friv.com  # flash games')
Assert-Equal 'trailing dot'        'friv.com'          (ConvertTo-CleanDomain 'friv.com.')
Assert-Equal 'comment line'        $null               (ConvertTo-CleanDomain '# header')
Assert-Equal 'empty line'          $null               (ConvertTo-CleanDomain '')
Assert-Equal 'raw IP skipped'      $null               (ConvertTo-CleanDomain '192.168.1.10')
Assert-Equal 'garbage skipped'     $null               (ConvertTo-CleanDomain 'not a domain')
Assert-Equal 'no tld skipped'      $null               (ConvertTo-CleanDomain 'localhost')

# --- Get-BlockEntries ---
$entries = Get-BlockEntries -Lines @('friv.com', 'FRIV.com', 'www.miniclip.com', '# c', '1.2.3.4', '')
Assert-Equal 'dedup + www, no IPs'   (@('0.0.0.0 friv.com', '0.0.0.0 www.friv.com', '0.0.0.0 www.miniclip.com') | Sort-Object) $entries
Assert-Equal 'NoWww'               @('0.0.0.0 friv.com') (Get-BlockEntries -Lines @('friv.com') -NoWww)

# --- hosts section management ---
$original = @('# Copyright (c) Microsoft', '127.0.0.1 localhost', '10.0.0.5 nas.local')
$withBlock = Add-BlockSection $original @('0.0.0.0 a.com') 'test'
Assert-Equal 'section added once'   1 (@($withBlock | Where-Object { $_ -eq $MarkerBegin }).Count)
Assert-Equal 'user lines kept'      $true (($withBlock -contains '10.0.0.5 nas.local') -and ($withBlock -contains '127.0.0.1 localhost'))

$reapplied = Add-BlockSection $withBlock @('0.0.0.0 b.com') 'test'
Assert-Equal 're-run replaces block' $false ($reapplied -contains '0.0.0.0 a.com')
Assert-Equal 're-run has new entry'  $true  ($reapplied -contains '0.0.0.0 b.com')
Assert-Equal 're-run single section' 1 (@($reapplied | Where-Object { $_ -eq $MarkerBegin }).Count)

$multi = Add-BlockSection $original @('0.0.0.0 c.com') @('https://a/list1', 'https://b/list2')
Assert-Equal 'one source line per list' 2 (@($multi | Where-Object { $_ -like '# source: *' }).Count)
Assert-Equal 'remove after multi-source' $original (Remove-BlockSection $multi)

# --- change detection (task skips rewriting hosts when nothing changed) ---
$sec = Get-BlockSectionEntries (Add-BlockSection $original @('0.0.0.0 a.com', '0.0.0.0 b.com') 'x')
Assert-Equal 'section entries read back'  @('0.0.0.0 a.com', '0.0.0.0 b.com') $sec
Assert-Equal 'same entries -> true'       $true  (Test-SameEntries $sec @('0.0.0.0 a.com', '0.0.0.0 b.com'))
Assert-Equal 'changed entry -> false'     $false (Test-SameEntries $sec @('0.0.0.0 a.com', '0.0.0.0 c.com'))
Assert-Equal 'different length -> false'  $false (Test-SameEntries $sec @('0.0.0.0 a.com'))
Assert-Equal 'no section -> empty'        0      (Get-BlockSectionEntries $original).Length

# --- fast path and slow path give the same result ---
Assert-Equal 'fast/slow path equal' (Get-BlockEntries -Lines @('friv.com')) (Get-BlockEntries -Lines @('  HTTPS://FRIV.com/ '))
Assert-Equal 'ordinal sort'         @('0.0.0.0 a-b.com', '0.0.0.0 ab.com') (Get-BlockEntries -Lines @('ab.com', 'a-b.com') -NoWww)

# --- allow list: the domain and all its subdomains stay open, look-alikes are still blocked
Assert-Equal 'allow: domain + subdomains skipped' @('0.0.0.0 notyoutube.com', '0.0.0.0 www.notyoutube.com') `
    (Get-BlockEntries -Lines @('youtube.com', 'm.youtube.com', 'www.youtube.com', 'notyoutube.com') -Allow @('youtube.com'))
Assert-Equal 'allow: list lines are cleaned'      @('0.0.0.0 a.com') `
    (Get-BlockEntries -Lines @('a.com', 'b.com') -Allow @('# comment', '', 'HTTPS://B.com/') -NoWww)
Assert-Equal 'allow: empty allow list'            @('0.0.0.0 a.com') (Get-BlockEntries -Lines @('a.com') -Allow @() -NoWww)

# --- hosts lines: 9 names per line (Windows DNS Client hangs on ~90k one-name lines)
$ten = 1..10 | ForEach-Object { "0.0.0.0 d$_.com" }
Assert-Equal '9 names per line'      @('0.0.0.0 d1.com d2.com d3.com d4.com d5.com d6.com d7.com d8.com d9.com', '0.0.0.0 d10.com') (ConvertTo-HostsLines $ten)
Assert-Equal 'single entry'          @('0.0.0.0 a.com') (ConvertTo-HostsLines @('0.0.0.0 a.com'))
Assert-Equal 'no entries'            0 (ConvertTo-HostsLines @()).Length
Assert-Equal 'old one-per-line differs' $false (Test-SameEntries (Get-BlockSectionEntries (Add-BlockSection $original $ten 'x')) (ConvertTo-HostsLines $ten))
Assert-Equal 'packed reads back same'  $true  (Test-SameEntries (Get-BlockSectionEntries (Add-BlockSection $original (ConvertTo-HostsLines $ten) 'x')) (ConvertTo-HostsLines $ten))

# --- scheduled task command ---
$taskCmd = Get-TaskCommand 'https://example.org/s.ps1'
Assert-Equal 'task cmd passes -FromTask'      $true ($taskCmd.EndsWith('-FromTask'))
Assert-Equal 'task cmd has no double quotes'  $false ($taskCmd.Contains('"'))
Assert-Equal 'task cmd parses'                $true ([bool][scriptblock]::Create($taskCmd))
Assert-Equal 'task cmd enables TLS 1.2 first'  $true ($taskCmd.StartsWith('[Net.ServicePointManager]::SecurityProtocol = ''Tls12''; '))

# --- custom-block.txt in repo ---
$custom = Get-BlockEntries -Lines (Get-Content "$PSScriptRoot/../custom-block.txt")
Assert-Equal 'custom: tiktok blocked'      $true  ($custom -contains '0.0.0.0 tiktok.com')
Assert-Equal 'custom: www.instagram added' $true  ($custom -contains '0.0.0.0 www.instagram.com')
Assert-Equal 'custom: commented ignored'   $false ($custom -contains '0.0.0.0 discord.com')
Assert-Equal 'custom: all lines valid'     0 (@(Get-Content "$PSScriptRoot/../custom-block.txt" |
    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') -and -not (ConvertTo-CleanDomain $_) }).Count)

# --- www. only for bare sites (fewer names keep the Windows DNS Client fast)
Assert-Equal 'www: bare site'          @('0.0.0.0 friv.com', '0.0.0.0 www.friv.com') (Get-BlockEntries -Lines @('friv.com'))
Assert-Equal 'www: bare site in com.ua' @('0.0.0.0 friv.com.ua', '0.0.0.0 www.friv.com.ua') (Get-BlockEntries -Lines @('friv.com.ua'))
Assert-Equal 'www: bare site in co.uk'  @('0.0.0.0 bbc.co.uk', '0.0.0.0 www.bbc.co.uk') (Get-BlockEntries -Lines @('bbc.co.uk'))
Assert-Equal 'www: subdomain gets none' @('0.0.0.0 m.tiktok.com') (Get-BlockEntries -Lines @('m.tiktok.com'))
Assert-Equal 'www: deep name gets none' @('0.0.0.0 a.b.nodes.gen4.ninja') (Get-BlockEntries -Lines @('a.b.nodes.gen4.ninja'))

# --- domains in NRPT-blocked zones stay out of hosts; look-alike endings are kept
Assert-Equal 'skip zones' @('0.0.0.0 friv.com', '0.0.0.0 rutube.com') `
    (Get-BlockEntries -Lines @('friv.com', 'kinogo.ru', 'm.kinogo.ru', 'twitch.tv', 'rutube.com') -SkipZones @('.ru', '.tv') -NoWww)
Assert-Equal 'skip zones: none given'   @('0.0.0.0 kinogo.ru') (Get-BlockEntries -Lines @('kinogo.ru') -NoWww)

# --- zones (NRPT): cleaned, sorted, protected zones never blocked
Assert-Equal 'zones: cleaned + sorted + dedup' @('.ru', '.to', '.tv') `
    (ConvertTo-TldNamespaces @('tv', '.TO', ' ru # comment', 'tv', '# c', ''))
Assert-Equal 'zones: punycode kept'      @('.xn--p1ai') (ConvertTo-TldNamespaces @('xn--p1ai'))
Assert-Equal 'zones: junk skipped'       0 (ConvertTo-TldNamespaces @('a', 'friv.com', 'not a zone', '*.tv')).Length
Assert-Equal 'zones: protected skipped'  @('.tv') (ConvertTo-TldNamespaces @('com', 'UA', '.net', 'org', 'tv') 3>$null)
Assert-Equal 'zones: repo file'          $true ((ConvertTo-TldNamespaces (Get-Content "$PSScriptRoot/../block-tld.txt")) -contains '.tv')
Assert-Equal 'zones: repo lines valid'   0 (@(Get-Content "$PSScriptRoot/../block-tld.txt" |
    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') -and (ConvertTo-TldNamespaces @($_)).Length -ne 1 }).Count)

Assert-Equal 'remove restores original' $original (Remove-BlockSection $reapplied)
Assert-Equal 'remove on clean hosts'    $original (Remove-BlockSection $original)

# --- real list (optional, needs network): set GAMEBLOCK_LIST_FILE to a downloaded copy ---
if ($env:GAMEBLOCK_LIST_FILE) {
    $real = Get-BlockEntries -Lines (Get-Content $env:GAMEBLOCK_LIST_FILE)
    Write-Host "INFO  real list -> $($real.Count) hosts entries"
    Assert-Equal 'real list is large'  $true ($real.Count -gt 10000)
    Assert-Equal 'real list no IPs'    0 (@($real | Where-Object { $_ -match '^0\.0\.0\.0 \d+\.\d+\.\d+\.\d+$' }).Count)
}

if ($script:failed) { Write-Host "$script:failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
