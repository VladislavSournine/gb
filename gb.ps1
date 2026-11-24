<#
.SYNOPSIS
    Short command for the game-block scripts:  gb sites | gb apps -Undo | gb find -All
.DESCRIPTION
    Every run downloads the LATEST script from GitHub and runs it with the given parameters,
    so changes in the repo reach every PC without reinstalling. Administrators only.
    Installed by install-gb.ps1 into a folder only administrators can write to.
#>

$RepoBase   = 'https://raw.githubusercontent.com/VladislavSournine/gb/main'
$InstallDir = "$env:ProgramFiles\SysTools"
$ShimPath   = "$env:SystemRoot\gb.cmd"
$Commands   = [ordered]@{ sites = 'block-games.ps1'; apps = 'block-apps.ps1'; find = 'find-games.ps1' }
$ArrayParams = @('-Extra', '-ListUrl')   # [string[]] parameters of the scripts

function Get-GbScript {
    param([string] $Name)
    foreach ($k in $Commands.Keys) { if ($k -ieq $Name) { return $Commands[$k] } }
    return $null
}

function ConvertTo-ForwardArgs {
    <# cmd.exe hands "-Extra a.com,b.com" over as ONE string; turn such values back into arrays.
       Elements are replaced in a copy of the array so parameter names (-Undo, ...) keep working when splatted. #>
    param([object[]] $Arguments)
    $a = @($Arguments)
    if ($a.Count -eq 1 -and $null -eq $a[0]) { return ,@() }   # "gb sites" alone: no stray $null positional argument
    for ($i = 1; $i -lt $a.Count; $i++) {
        if ($ArrayParams -contains "$($a[$i - 1])" -and "$($a[$i])".Contains(',')) { $a[$i] = [string[]]("$($a[$i])" -split ',') }
    }
    return ,$a
}

function Show-GbHelp {
    Write-Host @'
gb - game block (run in PowerShell as Administrator)

  gb sites                 block game sites (hosts) + install auto-update task
  gb sites -Remove         remove the site block, zone rules, the task and browser policies
  gb apps -AuditOnly       AppLocker test mode: only log what would be blocked
  gb apps                  block programs from apps-block.txt
  gb apps -Strict          only Windows + Program Files may run for students
  gb apps -Undo            roll back to the AppLocker policy before the last run
  gb apps -Remove          turn all AppLocker rules off
  gb find [-All] [-OutDir E:\]   find installed games (changes nothing)
  gb uninstall             remove the gb command from this PC

All parameters of the scripts work, see README in the repo.
'@
}

function Invoke-Gb {
    $name, $rest = $args
    if ($name -ieq 'uninstall') {
        Remove-Item -LiteralPath $ShimPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'gb removed. (The blocks themselves stay; remove them first with gb sites -Remove / gb apps -Remove.)' -ForegroundColor Green
        return
    }
    $file = Get-GbScript $name
    if (-not $file) {
        Show-GbHelp
        if ($name -and $name -notin @('help', '-h', '-?', '/?')) { Write-Host "Unknown command: $name" -ForegroundColor Red; exit 1 }
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $code = Invoke-RestMethod -UseBasicParsing "$RepoBase/$file" -ErrorAction Stop
    $forward = ConvertTo-ForwardArgs @($rest)   # @() here, not inside: a lone "-Undo" must stay a parameter name
    & ([scriptblock]::Create($code)) @forward
}

# Run unless dot-sourced (tests dot-source the file to load the functions only).
if ($MyInvocation.InvocationName -ne '.') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host 'gb: run PowerShell as Administrator.' -ForegroundColor Red; exit 1 }
    Invoke-Gb @args
}
