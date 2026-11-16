<#
.SYNOPSIS
    Finds games installed on a Windows PC and suggests AppLocker rules to block them.

.DESCRIPTION
    Scans every user profile (AppData, Desktop, Downloads, Documents), Program Files,
    common game folders on all fixed drives, and Microsoft Store packages.

    An .exe is reported as a game when its path / product / company matches a known
    game or launcher name, or when its folder contains game-engine files
    (UnityPlayer.dll, GameAssembly.dll, steam_api*.dll, Unreal "-Shipping.exe",
    Godot .pck, ...).

    Output (in -OutDir, file names contain the computer name so 20 PCs can share one folder):
      games-<PC>.csv            full list with paths, publishers, users
      apps-block-<PC>.txt       suggested rules in the format block-apps.ps1 reads

    Nothing is changed on the computer. Run as Administrator to see all user profiles.

.PARAMETER OutDir
    Where to save the results. Default: the current user's Desktop.
    Can be a USB stick or a network share, e.g. E:\ or \\server\share.

.PARAMETER All
    Also list non-game programs installed into user profiles (anything a student could
    have installed without admin rights). Marked as Category "UserApp".

.PARAMETER Pick
    Open a window (Out-GridView) to tick the rows you want; only those rules are saved.

.EXAMPLE
    irm https://raw.githubusercontent.com/VladislavSournine/gb/main/find-games.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/VladislavSournine/gb/main/find-games.ps1))) -OutDir E:\ -All
#>
[CmdletBinding()]
param(
    [string] $OutDir = [Environment]::GetFolderPath('Desktop'),
    [switch] $All,
    [switch] $Pick
)

# --- detection data -----------------------------------------------------------

$GameNameRegex = [regex]('(?i)(roblox|minecraft|tlauncher|\bsteam\b|epic ?games|fortnite|riot ?(games|client)|valorant|league of legends|' +
    'battle\.net|blizzard|genshin|hoyoverse|mihoyo|honkai|zenless|ubisoft|uplay|\borigin\b|\bea app\b|electronic arts|gog galaxy|' +
    'itch\.io|\bgarena\b|wargaming|world of tanks|brawlhalla|pubg|counter-?strike|\bcs2\b|\bdota|among us|geometry ?dash|' +
    'terraria|stumble guys|standoff|free ?fire|rockstar games|\bgta|grand theft|mojang|lunar ?client|badlion|feather ?client|' +
    'curseforge|overwolf|prism ?launcher|multimc|sklauncher|\bgames?\b|\bgaming\b|xbox ?games)')

$EngineFiles = @('UnityPlayer.dll', 'GameAssembly.dll', 'steam_api.dll', 'steam_api64.dll',
                 'EOSSDK-Win64-Shipping.dll', 'EOSSDK-Win32-Shipping.dll', 'galaxy64.dll', 'Galaxy.dll',
                 'fmod.dll', 'fmodex.dll', 'fmod64.dll', 'fmodstudio.dll', 'love.dll', 'renpy.exe', 'nw_elf.dll')

# exe names that are never the thing to report
$NoiseExeRegex = [regex]'(?i)^(unins\d*|uninstall.*|.*crash(pad|handler|reporter).*|unitycrashhandler(32|64)|vc_?redist.*|dxsetup|dotnet.*|setup|install(er)?|update(r)?|squirrel|elevate|notification_helper)\.exe$'

# folders not worth descending into (speed + no games inside)
$SkipDirRegex = [regex]'(?i)^(Microsoft|Windows|WindowsApps|Packages|Temp|INetCache|CrashDumps|D3DSCache|node_modules|\.git|Cache|Code Cache|GPUCache|Windows Defender|Windows Kits|Common Files|Microsoft Office|dotnet|Reference Assemblies|ModifiableWindowsApps|Google|Mozilla|Mozilla Firefox|Adobe|NVIDIA Corporation|Intel)$'

# development tools that contain game-engine files but are NOT games (Unity Editor ships UnityPlayer.dll etc.)
$DevToolPathRegex = [regex]'(?i)(\\Unity\\Hub\\|\\Unity Hub\\|\\Unity\\Editor\\|\\Editor\\Data\\|\\PlaybackEngines\\|\\Microsoft Visual Studio\\|\\JetBrains\\|\\Microsoft VS Code\\|\\Godot[^\\]*\\Godot[^\\]*\.exe$|\\Python\d*\\|\\nodejs\\|\\Git\\)'

# Store packages (Appx name match)
$StoreGameRegex   = [regex]'(?i)(minecraft(?!education)|roblox|solitaire|candycrush|king\.com|gameloft|asphalt|xboxapp|gamingapp|marchofempires|bubblewitch|farmheroes|hiddencity|zuma|mahjong|sudoku|chess)'
$StoreSocialRegex = [regex]'(?i)(tiktok|instagram|facebook|snapchat|discord)'

# publishers too broad to block as a whole (would break Windows / browsers)
$ProtectedPublisherRegex = [regex]'(?i)O=(MICROSOFT|GOOGLE|MOZILLA|ADOBE|INTEL|NVIDIA|ADVANCED MICRO DEVICES|APPLE|ORACLE|ZOOM|LENOVO|HP |DELL|REALTEK|UNITY TECHNOLOGIES|JETBRAINS|PYTHON SOFTWARE)'

# --- pure helpers (unit-tested) -------------------------------------------------

function Get-AppRoot {
    <# Returns the folder that represents "the app" for an exe path, used for path rules.
       C:\Users\kid\AppData\Local\Roblox\Versions\x\RobloxPlayerBeta.exe -> C:\Users\kid\AppData\Local\Roblox
       C:\Users\kid\AppData\Local\Programs\Lunar Client\Lunar.exe       -> ...\AppData\Local\Programs\Lunar Client
       C:\Users\kid\Downloads\game.exe                                   -> C:\Users\kid\Downloads\game.exe (the file itself)
       C:\Program Files (x86)\Steam\steamapps\common\X\x.exe              -> C:\Program Files (x86)\Steam
       D:\Games\Some Game\game.exe                                       -> D:\Games\Some Game #>
    param([string] $ExePath, [string] $ProgramFiles = 'C:\Program Files', [string] $ProgramFilesX86 = 'C:\Program Files (x86)')
    $p = $ExePath.TrimEnd('\')
    $parts = $p -split '\\'
    $take = $null

    if ($parts.Length -ge 4 -and $parts[1] -ieq 'Users') {
        # <drive>\Users\<user>\<area>...
        $area = $parts[3]
        if ($area -ieq 'AppData' -and $parts.Length -ge 6) {
            $take = 6                                      # AppData\Local\<App>
            if ($parts[5] -ieq 'Programs' -and $parts.Length -ge 7) { $take = 7 }   # AppData\Local\Programs\<App>
        } else {
            $take = 5                                      # Desktop\<App or file>
        }
    } else {
        foreach ($pf in @($ProgramFiles, $ProgramFilesX86)) {
            if ($pf -and $p.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $take = ($pf -split '\\').Length + 1
            }
        }
        if (-not $take) {
            if ($parts[1] -match '(?i)^(games|ігри|игры)$') { $take = 3 }   # D:\Games\<Game>
            else { $take = 2 }                                               # D:\SteamLibrary, C:\Riot Games
        }
    }
    if ($take -gt $parts.Length) { $take = $parts.Length }
    return ($parts[0..($take - 1)] -join '\')
}

function ConvertTo-AppLockerPath {
    <# Turns a concrete folder or file into an AppLocker path condition that works for every user.
       Folders get "\*" appended; user name is replaced with "*"; system folders use AppLocker variables. #>
    param([string] $Path, [switch] $IsFile, [string] $SystemDrive = 'C:',
          [string] $ProgramFiles = 'C:\Program Files', [string] $ProgramFilesX86 = 'C:\Program Files (x86)')
    $p = $Path.TrimEnd('\')
    $replaced = $false
    foreach ($pf in @($ProgramFilesX86, $ProgramFiles)) {          # x86 first: it is the longer prefix
        if (-not $replaced -and $pf -and ($p -ieq $pf -or $p.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase))) {
            $p = '%PROGRAMFILES%' + $p.Substring($pf.Length); $replaced = $true
        }
    }
    if (-not $replaced) {
        $usersPrefix = "$SystemDrive\Users\"
        if ($p.StartsWith($usersPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $p.Substring($usersPrefix.Length)
            $idx = $rest.IndexOf('\')
            if ($idx -ge 0) { $rest = $rest.Substring($idx) } else { $rest = '' }
            $p = '%OSDRIVE%\Users\*' + $rest; $replaced = $true
        } elseif ($p.StartsWith("$SystemDrive\", [StringComparison]::OrdinalIgnoreCase)) {
            $p = '%OSDRIVE%' + $p.Substring($SystemDrive.Length)
        }
    }
    if ($IsFile) { return $p }
    return "$p\*"
}

function Test-GameSignal {
    <# Decides whether an exe looks like a game. Returns the reason string, or $null. #>
    param([string] $ExePath, [string] $Product, [string] $Company, [string[]] $FolderFiles)
    $text = "$ExePath | $Product | $Company"
    $m = $GameNameRegex.Match($text)
    if ($m.Success) { return "name: $($m.Value)" }
    foreach ($f in $FolderFiles) {
        foreach ($e in $EngineFiles) { if ($f -ieq $e) { return "engine: $e" } }
        if ($f -like '*-Win64-Shipping.exe' -or $f -like '*-Win32-Shipping.exe') { return "engine: Unreal ($f)" }
        if ($f -like '*.pck') { return "engine: Godot ($f)" }
    }
    return $null
}

function Test-InsideUnityProject {
    <# True when the exe sits in (a build folder of) a Unity project: some parent folder has
       ProjectSettings\ProjectVersion.txt. Those are students' own builds from class, not games to block. #>
    param([string] $ExePath, [int] $Levels = 5)
    $d = [IO.Path]::GetDirectoryName($ExePath)
    for ($i = 0; $i -lt $Levels -and $d; $i++) {
        if ([IO.File]::Exists([IO.Path]::Combine($d, 'ProjectSettings', 'ProjectVersion.txt'))) { return $true }
        $d = [IO.Path]::GetDirectoryName($d)
    }
    return $false
}

function New-RuleLine {
    <# Builds the suggested block rule for one exe: publisher+product when signed by a non-generic
       publisher, otherwise a path rule for the app folder. #>
    param([string] $AppLockerPublisher, [string] $AppLockerProduct, [string] $AppRoot, [string] $ExePath,
          [string] $SystemDrive = 'C:', [string] $ProgramFiles = 'C:\Program Files', [string] $ProgramFilesX86 = 'C:\Program Files (x86)')
    if ($AppLockerPublisher -and -not $ProtectedPublisherRegex.IsMatch($AppLockerPublisher)) {
        $product = '*'; if ($AppLockerProduct) { $product = $AppLockerProduct }
        return "publisher: $AppLockerPublisher | $product"
    }
    $isFile = ($AppRoot -ieq $ExePath)
    return 'path: ' + (ConvertTo-AppLockerPath -Path $AppRoot -IsFile:$isFile -SystemDrive $SystemDrive -ProgramFiles $ProgramFiles -ProgramFilesX86 $ProgramFilesX86)
}

function Get-ExeFiles {
    <# Recursive .exe search that survives access-denied folders and skips heavy system folders. #>
    param([string] $Root, [int] $MaxDepth = 8)
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop(); $dir = $item[0]; $depth = $item[1]
        try { foreach ($f in [IO.Directory]::GetFiles($dir, '*.exe')) { $f } } catch { }
        if ($depth -ge $MaxDepth) { continue }
        try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($s in $subs) {
            $name = [IO.Path]::GetFileName($s)
            if ($SkipDirRegex.IsMatch($name)) { continue }
            try { if (([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint)) { continue } } catch { continue }
            $stack.Push(@($s, ($depth + 1)))
        }
    }
}

# --- scan -----------------------------------------------------------------------

function Get-ScanRoots {
    $sys = $env:SystemDrive
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($u in (Get-ChildItem "$sys\Users" -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($u.Name -match '^(Public|Default|Default User|All Users)$') { continue }
        foreach ($sub in 'AppData\Local', 'AppData\Roaming', 'Desktop', 'Downloads', 'Documents', 'OneDrive') {
            $p = Join-Path $u.FullName $sub
            if (Test-Path $p) { $roots.Add($p) }
        }
    }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) { if ($pf -and (Test-Path $pf)) { $roots.Add($pf) } }
    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        foreach ($name in 'Games', 'SteamLibrary', 'Steam', 'Epic Games', 'Riot Games', 'XboxGames', 'Ігри', 'Игры', 'Program Files\Steam') {
            $p = "$($d.DeviceID)\$name"
            if ((Test-Path $p) -and -not $roots.Contains($p)) { $roots.Add($p) }
        }
    }
    return $roots
}

function Find-Games {
    $hasAppLocker = [bool](Get-Command Get-AppLockerFileInformation -ErrorAction SilentlyContinue)
    $results = [System.Collections.Generic.List[object]]::new()
    $folderCache = @{}
    $sys = $env:SystemDrive; $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}

    foreach ($root in (Get-ScanRoots)) {
        Write-Host "Scanning $root"
        foreach ($exe in (Get-ExeFiles -Root $root)) {
            $name = [IO.Path]::GetFileName($exe)
            if ($NoiseExeRegex.IsMatch($name)) { continue }
            $dir = [IO.Path]::GetDirectoryName($exe)
            if (-not $folderCache.ContainsKey($dir)) {
                $files = @(); try { $files = [IO.Directory]::GetFiles($dir) | ForEach-Object { [IO.Path]::GetFileName($_) } } catch { }
                $folderCache[$dir] = $files
            }
            $vi = $null; try { $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe) } catch { }
            $product = ''; $company = ''
            if ($vi) { $product = "$($vi.ProductName)".Trim(); $company = "$($vi.CompanyName)".Trim() }

            if ($DevToolPathRegex.IsMatch($exe)) { continue }             # Unity Editor, Visual Studio, ...
            $inProfile = $exe.StartsWith("$sys\Users\", [StringComparison]::OrdinalIgnoreCase)
            if (Test-InsideUnityProject $exe) {
                # a student's own Unity build: list it for information, never suggest blocking
                $results.Add([pscustomobject]@{ Category = 'UnityProject'; App = $name; Exe = $name; User = $(if ($inProfile) { ($exe.Substring($sys.Length + 7) -split '\\')[0] } else { '' })
                    Company = $company; Signed = $false; Reason = 'own Unity project build'; Rule = ''; Path = $exe; Computer = $env:COMPUTERNAME })
                continue
            }
            $reason = Test-GameSignal -ExePath $exe -Product $product -Company $company -FolderFiles $folderCache[$dir]
            if ($reason) { $category = 'Game' }
            elseif ($All -and $inProfile) { $category = 'UserApp'; $reason = 'installed in user profile' }
            else { continue }

            $alPublisher = ''; $alProduct = ''
            if ($hasAppLocker) {
                try {
                    $info = Get-AppLockerFileInformation -Path $exe -ErrorAction Stop
                    if ($info.Publisher) { $alPublisher = $info.Publisher.PublisherName; $alProduct = $info.Publisher.ProductName }
                } catch { }
            }
            $user = ''; if ($inProfile) { $user = ($exe.Substring($sys.Length + 7) -split '\\')[0] }
            $appRoot = Get-AppRoot -ExePath $exe -ProgramFiles $pf -ProgramFilesX86 $pf86

            $results.Add([pscustomobject]@{
                Category  = $category
                App       = $(if ($product) { $product } else { [IO.Path]::GetFileName($appRoot) })
                Exe       = $name
                User      = $user
                Company   = $company
                Signed    = [bool]$alPublisher
                Reason    = $reason
                Rule      = New-RuleLine -AppLockerPublisher $alPublisher -AppLockerProduct $alProduct -AppRoot $appRoot -ExePath $exe `
                                         -SystemDrive $sys -ProgramFiles $pf -ProgramFilesX86 $pf86
                Path      = $exe
                Computer  = $env:COMPUTERNAME
            })
        }
    }

    # Microsoft Store apps
    Write-Host 'Scanning Microsoft Store apps'
    $pkgs = @()
    try { $pkgs = Get-AppxPackage -AllUsers -ErrorAction Stop } catch { try { $pkgs = Get-AppxPackage } catch { } }
    foreach ($pkg in $pkgs) {
        if ($pkg.IsFramework -or $pkg.SignatureKind -eq 'System') { continue }
        if     ($StoreGameRegex.IsMatch($pkg.Name))   { $category = 'Game' }
        elseif ($StoreSocialRegex.IsMatch($pkg.Name)) { $category = 'Social' }
        elseif ($All -and $pkg.SignatureKind -eq 'Store') { $category = 'UserApp' }
        else { continue }
        $results.Add([pscustomobject]@{
            Category = $category
            App      = $pkg.Name
            Exe      = '(Store app)'
            User     = ''
            Company  = $pkg.Publisher
            Signed   = $true
            Reason   = 'Microsoft Store package'
            Rule     = "appx: $($pkg.Publisher) | $($pkg.Name)"
            Path     = $pkg.InstallLocation
            Computer = $env:COMPUTERNAME
        })
    }
    return $results
}

function Format-RuleFile {
    <# Groups rows by rule and writes them as an apps-block.txt fragment with app names as comments. #>
    param([object[]] $Rows, [string] $Computer)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("# Suggested by find-games.ps1 on $Computer, $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $out.Add('# Review, delete lines you do NOT want to block, then copy the rest to apps-block.txt')
    foreach ($g in ($Rows | Where-Object { $_.Rule } | Group-Object Rule | Sort-Object { $_.Group[0].Category }, Name)) {
        $first = $g.Group[0]
        $apps  = ($g.Group | ForEach-Object { $_.App } | Sort-Object -Unique) -join ', '
        $users = ($g.Group | Where-Object { $_.User } | ForEach-Object { $_.User } | Sort-Object -Unique) -join ', '
        $out.Add('')
        $comment = "# [$($first.Category)] $apps ($($first.Reason))"
        if ($users) { $comment += " users: $users" }
        $out.Add($comment)
        $out.Add($g.Name)
    }
    return ,$out.ToArray()
}

function Invoke-FindGames {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Warning 'Not running as Administrator: other users'' profiles may be skipped.' }

    $rows = @(Find-Games)
    if ($rows.Count -eq 0) { Write-Host 'No games found.' -ForegroundColor Green; return }

    if ($Pick) {
        $rows = @($rows | Out-GridView -Title 'Select programs to block (Ctrl+click), then OK' -PassThru)
        if ($rows.Count -eq 0) { Write-Host 'Nothing selected.'; return }
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $csv   = Join-Path $OutDir "games-$env:COMPUTERNAME.csv"
    $rules = Join-Path $OutDir "apps-block-$env:COMPUTERNAME.txt"
    $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    [IO.File]::WriteAllLines($rules, (Format-RuleFile -Rows $rows -Computer $env:COMPUTERNAME), [Text.UTF8Encoding]::new($false))

    $rows | Sort-Object Category, App | Format-Table Category, App, Exe, User, Reason -AutoSize | Out-Host
    Write-Host "Found $($rows.Count) programs." -ForegroundColor Green
    Write-Host "  List:  $csv"
    Write-Host "  Rules: $rules"
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-FindGames }
