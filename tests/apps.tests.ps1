# Dependency-free tests for find-games.ps1 and block-apps.ps1:  pwsh ./tests/apps.tests.ps1
# They only test pure logic (paths, detection, rule parsing, policy XML); nothing on the system is changed.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../find-games.ps1"
. "$PSScriptRoot/../block-apps.ps1"

$script:failed = 0
function Assert-Equal($Name, $Expected, $Actual) {
    $e = ($Expected | Out-String).Trim(); $a = ($Actual | Out-String).Trim()
    if ($e -ceq $a) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name`n  expected: $e`n  actual:   $a" -ForegroundColor Red; $script:failed++ }
}

# ===== find-games.ps1 =====

# --- Get-AppRoot
Assert-Equal 'root: AppData app'        'C:\Users\kid\AppData\Local\Roblox' (Get-AppRoot 'C:\Users\kid\AppData\Local\Roblox\Versions\v1\RobloxPlayerBeta.exe')
Assert-Equal 'root: Roaming app'        'C:\Users\kid\AppData\Roaming\.minecraft' (Get-AppRoot 'C:\Users\kid\AppData\Roaming\.minecraft\runtime\java.exe')
Assert-Equal 'root: Local\Programs app' 'C:\Users\kid\AppData\Local\Programs\Lunar Client' (Get-AppRoot 'C:\Users\kid\AppData\Local\Programs\Lunar Client\Lunar Client.exe')
Assert-Equal 'root: file in Downloads'  'C:\Users\kid\Downloads\game.exe' (Get-AppRoot 'C:\Users\kid\Downloads\game.exe')
Assert-Equal 'root: folder in Desktop'  'C:\Users\kid\Desktop\MyGame' (Get-AppRoot 'C:\Users\kid\Desktop\MyGame\bin\game.exe')
Assert-Equal 'root: Program Files x86'  'C:\Program Files (x86)\Steam' (Get-AppRoot 'C:\Program Files (x86)\Steam\steamapps\common\X\x.exe')
Assert-Equal 'root: Program Files'      'C:\Program Files\Epic Games' (Get-AppRoot 'C:\Program Files\Epic Games\Fortnite\f.exe')
Assert-Equal 'root: D:\Games\X'         'D:\Games\Some Game' (Get-AppRoot 'D:\Games\Some Game\bin\game.exe')
Assert-Equal 'root: D:\SteamLibrary'    'D:\SteamLibrary' (Get-AppRoot 'D:\SteamLibrary\steamapps\common\X\x.exe')
Assert-Equal 'root: C:\Riot Games'      'C:\Riot Games' (Get-AppRoot 'C:\Riot Games\VALORANT\live\VALORANT.exe')

# --- ConvertTo-AppLockerPath
Assert-Equal 'al: user folder'   '%OSDRIVE%\Users\*\AppData\Local\Roblox\*' (ConvertTo-AppLockerPath 'C:\Users\kid\AppData\Local\Roblox')
Assert-Equal 'al: user file'     '%OSDRIVE%\Users\*\Downloads\game.exe'     (ConvertTo-AppLockerPath 'C:\Users\kid\Downloads\game.exe' -IsFile)
Assert-Equal 'al: PF x86'        '%PROGRAMFILES%\Steam\*'                   (ConvertTo-AppLockerPath 'C:\Program Files (x86)\Steam')
Assert-Equal 'al: PF'            '%PROGRAMFILES%\Epic Games\*'              (ConvertTo-AppLockerPath 'C:\Program Files\Epic Games')
Assert-Equal 'al: system drive'  '%OSDRIVE%\Riot Games\*'                   (ConvertTo-AppLockerPath 'C:\Riot Games')
Assert-Equal 'al: other drive'   'D:\Games\Some Game\*'                     (ConvertTo-AppLockerPath 'D:\Games\Some Game')

# --- Test-GameSignal
Assert-Equal 'signal: name'     'name: Roblox' (Test-GameSignal 'C:\Users\k\AppData\Local\Roblox\x.exe' '' '' @())
Assert-Equal 'signal: Unity'    'engine: UnityPlayer.dll' (Test-GameSignal 'C:\Users\k\Desktop\Zzz\zzz.exe' 'Zzz' 'Indie' @('zzz.exe', 'UnityPlayer.dll'))
Assert-Equal 'signal: Unreal'   'engine: Unreal (Zzz-Win64-Shipping.exe)' (Test-GameSignal 'D:\Zzz\Zzz.exe' '' '' @('Zzz-Win64-Shipping.exe'))
Assert-Equal 'signal: Godot'    'engine: Godot (zzz.pck)' (Test-GameSignal 'D:\Zzz\zzz.exe' '' '' @('zzz.exe', 'zzz.pck'))
Assert-Equal 'signal: Steam API' 'engine: steam_api64.dll' (Test-GameSignal 'D:\Zzz\zzz.exe' '' '' @('steam_api64.dll'))
Assert-Equal 'signal: none'     $null (Test-GameSignal 'C:\Program Files\Notepad++\notepad++.exe' 'Notepad++' 'Don Ho' @('notepad++.exe', 'SciLexer.dll'))
Assert-Equal 'signal: no false hit on "origin" inside word' $null (Test-GameSignal 'C:\Program Files\Originality\o.exe' 'Originality' '' @())

# --- Unity classes: editor is a dev tool, student builds are not games
Assert-Equal 'dev: Unity Hub editor'      $true  ($DevToolPathRegex.IsMatch('C:\Program Files\Unity\Hub\Editor\2022.3.10f1\Editor\Unity.exe'))
Assert-Equal 'dev: PlaybackEngines player' $true ($DevToolPathRegex.IsMatch('C:\Program Files\Unity\Hub\Editor\2022.3.10f1\Editor\Data\PlaybackEngines\windowsstandalonesupport\Variations\x\WindowsPlayer.exe'))
Assert-Equal 'dev: Unity Hub app'         $true  ($DevToolPathRegex.IsMatch('C:\Program Files\Unity Hub\Unity Hub.exe'))
Assert-Equal 'dev: VS Code user install'  $true  ($DevToolPathRegex.IsMatch('C:\Users\k\AppData\Local\Programs\Microsoft VS Code\Code.exe'))
Assert-Equal 'dev: a real game is not a dev tool' $false ($DevToolPathRegex.IsMatch('C:\Users\k\Desktop\HollowKnight\hollow_knight.exe'))

$proj = Join-Path ([IO.Path]::GetTempPath()) ("gb-unity-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path "$proj/MyGame/ProjectSettings", "$proj/MyGame/Builds/Win64", "$proj/Downloaded" | Out-Null
'm_EditorVersion: 2022.3.10f1' | Set-Content "$proj/MyGame/ProjectSettings/ProjectVersion.txt"
Assert-Equal 'unity: build inside project'    $true  (Test-InsideUnityProject ([IO.Path]::Combine($proj, 'MyGame', 'Builds', 'Win64', 'MyGame.exe')))
Assert-Equal 'unity: downloaded game is not'  $false (Test-InsideUnityProject ([IO.Path]::Combine($proj, 'Downloaded', 'game.exe')))
Remove-Item -Recurse -Force $proj

Assert-Equal 'rulefile: rows without rule skipped' 0 (@(Format-RuleFile -Rows @([pscustomobject]@{ Category = 'UnityProject'; App = 'x'; User = ''; Reason = 'own'; Rule = '' }) -Computer 'PC' | Where-Object { $_ -match '^(path|publisher|appx):' }).Count)

# --- New-RuleLine
Assert-Equal 'rule: signed -> publisher' 'publisher: O=ROBLOX CORPORATION, C=US | ROBLOX' `
    (New-RuleLine 'O=ROBLOX CORPORATION, C=US' 'ROBLOX' 'C:\Users\k\AppData\Local\Roblox' 'C:\Users\k\AppData\Local\Roblox\v\r.exe')
Assert-Equal 'rule: no product -> *' 'publisher: O=X GAMES, C=US | *' (New-RuleLine 'O=X GAMES, C=US' '' 'D:\X' 'D:\X\x.exe')
Assert-Equal 'rule: Microsoft-signed -> path, not publisher' '%PROGRAMFILES%\Minecraft Launcher\*'.Insert(0, 'path: ') `
    (New-RuleLine 'O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US' 'MINECRAFT LAUNCHER' 'C:\Program Files (x86)\Minecraft Launcher' 'C:\Program Files (x86)\Minecraft Launcher\MinecraftLauncher.exe')
Assert-Equal 'rule: unsigned file in Downloads' 'path: %OSDRIVE%\Users\*\Downloads\game.exe' (New-RuleLine '' '' 'C:\Users\k\Downloads\game.exe' 'C:\Users\k\Downloads\game.exe')

# --- Get-ExeFiles on a fake tree
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("gb-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path "$tmp/Roblox/Versions/v1", "$tmp/Microsoft/Teams", "$tmp/Deep/a/b/c" | Out-Null
'x' | Set-Content "$tmp/Roblox/Versions/v1/RobloxPlayerBeta.exe"
'x' | Set-Content "$tmp/Microsoft/Teams/Teams.exe"
'x' | Set-Content "$tmp/Deep/a/b/c/deep.exe"
'x' | Set-Content "$tmp/readme.txt"
$found = @(Get-ExeFiles -Root $tmp | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
Assert-Equal 'scan: finds exes, skips Microsoft folder' @('deep.exe', 'RobloxPlayerBeta.exe') $found
Assert-Equal 'scan: respects depth' @('RobloxPlayerBeta.exe') @(Get-ExeFiles -Root $tmp -MaxDepth 3 | ForEach-Object { [IO.Path]::GetFileName($_) })
Remove-Item -Recurse -Force $tmp

# --- Format-RuleFile
$rows = @(
    [pscustomobject]@{ Category = 'Game'; App = 'Roblox'; User = 'kid1'; Reason = 'name: Roblox'; Rule = 'path: %OSDRIVE%\Users\*\AppData\Local\Roblox\*' },
    [pscustomobject]@{ Category = 'Game'; App = 'Roblox'; User = 'kid2'; Reason = 'name: Roblox'; Rule = 'path: %OSDRIVE%\Users\*\AppData\Local\Roblox\*' },
    [pscustomobject]@{ Category = 'Game'; App = 'Steam';  User = '';     Reason = 'name: Steam';  Rule = 'path: %PROGRAMFILES%\Steam\*' }
)
$ruleFile = Format-RuleFile -Rows $rows -Computer 'PC-01'
Assert-Equal 'rulefile: one line per rule' 2 (@($ruleFile | Where-Object { $_ -like 'path:*' }).Count)
Assert-Equal 'rulefile: users listed'      $true ([bool]($ruleFile | Where-Object { $_ -like '*users: kid1, kid2*' }))

# ===== block-apps.ps1 =====

# --- ConvertFrom-RuleLine
Assert-Equal 'parse: comment'   $null (ConvertFrom-RuleLine '# hello')
Assert-Equal 'parse: blank'     $null (ConvertFrom-RuleLine '   ')
Assert-Equal 'parse: trailing comment' '%PROGRAMFILES%\Steam\*' (ConvertFrom-RuleLine 'path: %PROGRAMFILES%\Steam\*    # Steam').Path
$r = ConvertFrom-RuleLine 'path: %PROGRAMFILES%\Steam\*'
Assert-Equal 'parse: path'      'path|%PROGRAMFILES%\Steam\*' "$($r.Type)|$($r.Path)"
$r = ConvertFrom-RuleLine 'publisher: O=VALVE CORP., L=BELLEVUE, S=WASHINGTON, C=US | STEAM'
Assert-Equal 'parse: publisher' 'publisher|O=VALVE CORP., L=BELLEVUE, S=WASHINGTON, C=US|STEAM' "$($r.Type)|$($r.Publisher)|$($r.Product)"
$r = ConvertFrom-RuleLine 'publisher: O=ROBLOX CORPORATION, C=US'
Assert-Equal 'parse: publisher default product *' '*' $r.Product
$r = ConvertFrom-RuleLine 'appx: CN=Microsoft Corporation, O=Microsoft Corporation, C=US | Microsoft.MinecraftUWP'
Assert-Equal 'parse: appx'      'appx|Microsoft.MinecraftUWP' "$($r.Type)|$($r.Product)"
Assert-Equal 'parse: unknown type -> error'          $true ([bool](ConvertFrom-RuleLine 'hash: 123').Error)
Assert-Equal 'parse: block-all path -> error'        $true ([bool](ConvertFrom-RuleLine 'path: *').Error)
Assert-Equal 'parse: Windows folder -> error'        $true ([bool](ConvertFrom-RuleLine 'path: %WINDIR%\*').Error)
Assert-Equal 'parse: relative path -> error'         $true ([bool](ConvertFrom-RuleLine 'path: Steam\*').Error)
Assert-Equal 'parse: whole Microsoft -> error'       $true ([bool](ConvertFrom-RuleLine 'publisher: O=MICROSOFT CORPORATION, C=US | *').Error)
Assert-Equal 'parse: allow'                   'allow|%OSDRIVE%\Users\*\Documents\UnityProjects\*' "$((ConvertFrom-RuleLine 'allow: %OSDRIVE%\Users\*\Documents\UnityProjects\*').Type)|$((ConvertFrom-RuleLine 'allow: %OSDRIVE%\Users\*\Documents\UnityProjects\*').Path)"
Assert-Equal 'parse: allow whole disk -> error'  $true ([bool](ConvertFrom-RuleLine 'allow: %OSDRIVE%\*').Error)
Assert-Equal 'parse: allow * -> error'           $true ([bool](ConvertFrom-RuleLine 'allow: *').Error)
Assert-Equal 'parse: whole Unity publisher -> error' $true ([bool](ConvertFrom-RuleLine 'publisher: O=UNITY TECHNOLOGIES APS, C=DK | *').Error)
Assert-Equal 'parse: Microsoft + product -> ok'      $false ([bool](ConvertFrom-RuleLine 'publisher: O=MICROSOFT CORPORATION, C=US | MINECRAFT LAUNCHER').Error)

# --- rule lines produced by find-games are accepted by block-apps (round trip)
foreach ($line in @(
    (New-RuleLine 'O=ROBLOX CORPORATION, C=US' 'ROBLOX' 'x' 'y'),
    (New-RuleLine '' '' 'C:\Users\k\AppData\Local\Roblox' 'C:\Users\k\AppData\Local\Roblox\r.exe'),
    (New-RuleLine '' '' 'C:\Users\k\Downloads\g.exe' 'C:\Users\k\Downloads\g.exe'),
    (New-RuleLine '' '' 'D:\Games\X' 'D:\Games\X\x.exe'))) {
    Assert-Equal "roundtrip: $line" $null (ConvertFrom-RuleLine $line).Error
}

# --- policy XML
$rules = @(
    (ConvertFrom-RuleLine 'path: %PROGRAMFILES%\Steam\*'),
    (ConvertFrom-RuleLine 'path: %PROGRAMFILES%\Steam\*'),          # duplicate on purpose
    (ConvertFrom-RuleLine 'publisher: O=ROBLOX CORPORATION, C=US | *'),
    (ConvertFrom-RuleLine 'appx: CN=Microsoft Corporation, O=Microsoft Corporation, C=US | Microsoft.MinecraftUWP')
)
$x = [xml](New-AppLockerPolicyXml -Rules $rules)
$exe = $x.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Exe'
$appx = $x.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Appx'
Assert-Equal 'xml: exe enforced'            'Enabled' $exe.EnforcementMode
Assert-Equal 'xml: allow-all + 2 deny (dup removed)' 3 @($exe.ChildNodes).Count
Assert-Equal 'xml: allow-all rule'          '*' ($exe.FilePathRule | Where-Object Action -eq 'Allow').Conditions.FilePathCondition.Path
Assert-Equal 'xml: path deny'               '%PROGRAMFILES%\Steam\*' ($exe.FilePathRule | Where-Object Action -eq 'Deny').Conditions.FilePathCondition.Path
Assert-Equal 'xml: publisher deny'          'O=ROBLOX CORPORATION, C=US' $exe.FilePublisherRule.Conditions.FilePublisherCondition.PublisherName
Assert-Equal 'xml: deny applies to Everyone' 'S-1-1-0' $exe.FilePublisherRule.UserOrGroupSid
Assert-Equal 'xml: appx collection'         2 @($appx.ChildNodes).Count
Assert-Equal 'xml: appx deny product'       'Microsoft.MinecraftUWP' ($appx.FilePublisherRule | Where-Object Action -eq 'Deny').Conditions.FilePublisherCondition.ProductName
$ids = @($x.SelectNodes('//*[@Id]') | ForEach-Object { $_.Id })
Assert-Equal 'xml: rule ids unique'         $ids.Count @($ids | Sort-Object -Unique).Count
Assert-Equal 'xml: deterministic'           (New-AppLockerPolicyXml -Rules $rules) (New-AppLockerPolicyXml -Rules $rules)

$xa = [xml](New-AppLockerPolicyXml -Rules @($rules[0]) -AuditOnly)
Assert-Equal 'xml: audit mode'              'AuditOnly' (@($xa.AppLockerPolicy.RuleCollection.EnforcementMode) | Sort-Object -Unique)
$xaAppx = $xa.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Appx'
Assert-Equal 'xml: appx allow-all ALWAYS present (else Settings/Store apps get blocked)' 'Allow *' "$($xaAppx.FilePublisherRule.Action) $($xaAppx.FilePublisherRule.Conditions.FilePublisherCondition.PublisherName)" 

$xs = [xml](New-AppLockerPolicyXml -Rules @($rules[0]) -Strict)
$allows = @(($xs.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Exe').FilePathRule | Where-Object Action -eq 'Allow' | ForEach-Object { "$($_.UserOrGroupSid) $($_.Conditions.FilePathCondition.Path)" })
Assert-Equal 'xml: strict allow rules' @('S-1-1-0 %WINDIR%\*', 'S-1-1-0 %PROGRAMFILES%\*', 'S-1-5-32-544 *') $allows

$allowRule = ConvertFrom-RuleLine 'allow: %OSDRIVE%\Users\*\Documents\UnityProjects\*'
$xs2 = [xml](New-AppLockerPolicyXml -Rules @($rules[0], $allowRule) -Strict)
Assert-Equal 'xml: strict includes allow: lines' $true ([bool](($xs2.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Exe').FilePathRule | Where-Object { $_.Action -eq 'Allow' -and $_.Conditions.FilePathCondition.Path -like '*UnityProjects*' }))
$xd2 = [xml](New-AppLockerPolicyXml -Rules @($rules[0], $allowRule))
Assert-Equal 'xml: deny-list mode ignores allow: lines' 2 @(($xd2.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Exe').ChildNodes).Count

$xe = [xml](New-EmptyPolicyXml)
Assert-Equal 'xml: empty policy has no rules' 0 @($xe.SelectNodes('//*[@Action]')).Count
Assert-Equal 'xml: empty policy not configured' 'NotConfigured' (@($xe.AppLockerPolicy.RuleCollection.EnforcementMode) | Sort-Object -Unique)

# --- undo: pick the newest backup, validate backup files
$bk = Join-Path ([IO.Path]::GetTempPath()) ("gb-undo-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Assert-Equal 'undo: no backups -> null' $null (Get-UndoBackup $bk)
'<AppLockerPolicy Version="1" />' | Set-Content "$bk/applocker-backup-20261110-101500.xml"
'<AppLockerPolicy Version="1" />' | Set-Content "$bk/applocker-backup-20261116-090000.xml"
'<AppLockerPolicy Version="1" />' | Set-Content "$bk/applocker-undone-20261117-090000.xml"
'<AppLockerPolicy Version="1" />' | Set-Content "$bk/applocker-before-undo-20261118-090000.xml"
Assert-Equal 'undo: newest backup, ignores undone/before-undo' 'applocker-backup-20261116-090000.xml' ([IO.Path]::GetFileName((Get-UndoBackup $bk)))
Assert-Equal 'undo: missing dir -> null' $null (Get-UndoBackup (Join-Path $bk 'nope'))
Assert-Equal 'backup: valid policy read'  '<AppLockerPolicy Version="1" />' (Read-PolicyBackup "$bk/applocker-backup-20261116-090000.xml")
'not xml' | Set-Content "$bk/bad.xml"
'<Other />' | Set-Content "$bk/other.xml"
foreach ($case in @(@('missing file', "$bk/missing.xml"), @('not xml', "$bk/bad.xml"), @('not AppLocker', "$bk/other.xml"))) {
    $threw = $false; try { Read-PolicyBackup $case[1] | Out-Null } catch { $threw = $true }
    Assert-Equal "backup: $($case[0]) -> throws" $true $threw
}
Remove-Item -Recurse -Force $bk

# --- the shipped apps-block.txt is valid
$shipped = @(Get-Content "$PSScriptRoot/../apps-block.txt" | ForEach-Object { ConvertFrom-RuleLine $_ } | Where-Object { $_ })
Assert-Equal 'apps-block.txt: no invalid lines' 0 @($shipped | Where-Object { $_.Error }).Count
Assert-Equal 'apps-block.txt: has rules'        $true ($shipped.Count -gt 10)
Assert-Equal 'apps-block.txt: builds valid xml' $true ([bool]([xml](New-AppLockerPolicyXml -Rules $shipped)))

if ($script:failed) { Write-Host "$script:failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
