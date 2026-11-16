# Dependency-free tests for tools/add-rules.ps1:  pwsh ./tests/add-rules.tests.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../tools/add-rules.ps1"

$script:failed = 0
function Assert-Equal($Name, $Expected, $Actual) {
    $e = ($Expected | Out-String).Trim(); $a = ($Actual | Out-String).Trim()
    if ($e -ceq $a) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name`n  expected: $e`n  actual:   $a" -ForegroundColor Red; $script:failed++ }
}
function Body([string[]] $Lines) { "### Правила`n`n``````text`n" + ($Lines -join "`r`n") + "`n```````n" }

$existing = "# list`npath: %PROGRAMFILES%\Steam\*`n"

# --- only lines inside the code fence are read
Assert-Equal 'pasted: inside fence only' "a`nb" ((Get-PastedLines "intro`n``````text`na`nb`n```````noutro") -join "`n")

# --- new rules are appended with their comments under an issue header
$r = Add-IssueRules $existing (Body '# [Game] Roblox', 'path: %OSDRIVE%\Users\*\AppData\Local\Roblox\*') 7
Assert-Equal 'add: count'  1 $r.Added
Assert-Equal 'add: text'   "# list`npath: %PROGRAMFILES%\Steam\*`n`n# --- issue #7 ---`n# [Game] Roblox`npath: %OSDRIVE%\Users\*\AppData\Local\Roblox\*`n" $r.Text

# --- duplicates (case/space-insensitive, against the file and within the paste) are skipped with their comment
$r = Add-IssueRules $existing (Body '# [Game] Steam', 'PATH:  %PROGRAMFILES%\steam\*', '# [Game] X', 'path: C:\X\*', 'path: C:\X\*') 8
Assert-Equal 'dup: added'    1 $r.Added
Assert-Equal 'dup: skipped'  2 $r.Skipped
Assert-Equal 'dup: steam comment dropped' $false ($r.Text -like '*[[]Game] Steam*')

# --- all duplicates -> no change
$r = Add-IssueRules $existing (Body 'path: %PROGRAMFILES%\Steam\*') 9
Assert-Equal 'nothing new: no text' $null $r.Text
Assert-Equal 'nothing new: reply'   $true ((Format-Reply $r) -like 'Нічого нового*')

# --- one bad rule -> nothing is added
$r = Add-IssueRules $existing (Body 'path: C:\Good\*', 'path: %WINDIR%\*', 'Roblox.exe') 10
Assert-Equal 'error: no text'   $null $r.Text
Assert-Equal 'error: both bad lines reported' 2 $r.Errors.Count
Assert-Equal 'error: reply'     $true ((Format-Reply $r) -like 'Нічого не додано*')

# --- empty form
$r = Add-IssueRules $existing 'no fence here' 11
Assert-Equal 'empty: no text' $null $r.Text
Assert-Equal 'empty: added 0' 0 $r.Added

if ($script:failed) { Write-Host "$script:failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
