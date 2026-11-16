# Dependency-free tests for gb.ps1 and install-gb.ps1:  pwsh ./tests/gb.tests.ps1
# Only pure logic (command mapping, argument forwarding, cmd shim text); nothing is downloaded or installed.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../gb.ps1"
. "$PSScriptRoot/../install-gb.ps1"

$script:failed = 0
function Assert-Equal($Name, $Expected, $Actual) {
    $e = ($Expected | Out-String).Trim(); $a = ($Actual | Out-String).Trim()
    if ($e -ceq $a) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name`n  expected: $e`n  actual:   $a" -ForegroundColor Red; $script:failed++ }
}

# --- command -> script
Assert-Equal 'map: sites'          'block-games.ps1' (Get-GbScript 'sites')
Assert-Equal 'map: apps'           'block-apps.ps1'  (Get-GbScript 'apps')
Assert-Equal 'map: find'           'find-games.ps1'  (Get-GbScript 'find')
Assert-Equal 'map: case-insensitive' 'block-apps.ps1' (Get-GbScript 'APPS')
Assert-Equal 'map: unknown -> null' $null (Get-GbScript 'hack')
Assert-Equal 'map: empty -> null'   $null (Get-GbScript '')

# --- arguments are forwarded with parameter names intact; "-Extra a,b" from cmd.exe becomes an array
# Invoke-Probe splits its args exactly like Invoke-Gb; the probe script has a positional [string[]] first
# parameter like block-games.ps1, so a stray $null argument would show up as List=1.
function Invoke-Probe { $name, $rest = $args; $f = ConvertTo-ForwardArgs @($rest)
    & { param([string[]]$ListUrl = @('default'), [switch]$Undo, [string]$RulesFile, [string[]]$Extra)
        "Undo=$Undo File=[$RulesFile] Extra=$($Extra.Count):$($Extra -join ';') List=$($ListUrl -join ';')" } @f }
Assert-Equal 'args: none -> script defaults' 'Undo=False File=[] Extra=0: List=default'       (Invoke-Probe sites)
Assert-Equal 'args: switch'            'Undo=True File=[] Extra=0: List=default'               (Invoke-Probe apps -Undo)
Assert-Equal 'args: value with space'  'Undo=False File=[E:\a b.txt] Extra=0: List=default'    (Invoke-Probe apps -RulesFile 'E:\a b.txt')
Assert-Equal 'args: -Extra a,b split'  'Undo=False File=[] Extra=2:a.com;b.com List=default'   (Invoke-Probe sites -Extra 'a.com,b.com')
Assert-Equal 'args: -ListUrl split'    'Undo=False File=[] Extra=0: List=https://a/x;https://b/y' (Invoke-Probe sites -ListUrl 'https://a/x,https://b/y')
Assert-Equal 'args: comma elsewhere kept' 'Undo=False File=[E:\a,b.txt] Extra=0: List=default' (Invoke-Probe apps -RulesFile 'E:\a,b.txt')

# --- cmd shim
$shim = Get-CmdShim 'C:\Program Files\SysTools\gb.ps1'
Assert-Equal 'shim: bypasses execution policy' $true ($shim -like '*-ExecutionPolicy Bypass*')
Assert-Equal 'shim: quoted script path'        $true ($shim.Contains('-File "C:\Program Files\SysTools\gb.ps1"'))
Assert-Equal 'shim: forwards all args'         $true ($shim.TrimEnd().EndsWith('%*'))

if ($script:failed) { Write-Host "$script:failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
