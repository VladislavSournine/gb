<#
.SYNOPSIS
    Blocks programs (games) on a Windows PC with AppLocker, from a plain-text rules list.

.DESCRIPTION
    Reads apps-block.txt (from GitHub by default, or a local file), builds an AppLocker
    policy and applies it as the computer's local policy. No mouse work in secpol.msc.

    Rule lines (one per line, # starts a comment):
      publisher: O=ROBLOX CORPORATION, L=SAN MATEO, S=CALIFORNIA, C=US | *
      publisher: O=VALVE CORP., L=BELLEVUE, S=WASHINGTON, C=US | STEAM
      path: %OSDRIVE%\Users\*\AppData\Local\Roblox\*
      path: %PROGRAMFILES%\Steam\*
      appx: CN=..., O=..., C=US | Microsoft.MinecraftUWP
      allow: %OSDRIVE%\Users\*\Documents\UnityProjects\*
    find-games.ps1 produces exactly these lines (except allow:).
    allow: lines matter only with -Strict: extra folders students may run programs from
    (their Unity builds, VS Code user install...). A block rule always wins over allow.

    Modes:
      default   deny list: everything runs except the listed programs.
      -Strict   allow list: only Windows and Program Files run for everyone; administrators
                run anything. Every program a student put into AppData, Downloads, Desktop,
                a USB stick etc. is blocked, plus the listed programs.
      -AuditOnly  nothing is blocked, AppLocker only writes to the event log what it WOULD
                block (Event Viewer > Applications and Services > Microsoft > Windows >
                AppLocker > EXE and DLL). Good for a first test.

    The previous local AppLocker policy is saved to C:\ProgramData\GameBlock before it is replaced.
    That folder is locked to Administrators and SYSTEM, so students cannot plant files there.

.PARAMETER RulesUrl
    URL of the rules list. Default: apps-block.txt in the GitHub repo.

.PARAMETER RulesFile
    Local rules file; when given, RulesUrl is not used.

.PARAMETER Remove
    Turn AppLocker rules off (empty local policy). Programs run again.

.PARAMETER Undo
    Roll back: put back the policy that was there before the last run of this script.
    Each -Undo goes one more step back (the used backup is renamed to applocker-undone-*.xml).

.PARAMETER BackupFile
    Restore the policy from this backup file (e.g. C:\ProgramData\GameBlock\applocker-backup-*.xml).

.EXAMPLE
    irm https://raw.githubusercontent.com/VladislavSournine/gb/main/block-apps.ps1 | iex

.EXAMPLE
    $u = 'https://raw.githubusercontent.com/VladislavSournine/gb/main/block-apps.ps1'
    & ([scriptblock]::Create((irm $u))) -AuditOnly
    & ([scriptblock]::Create((irm $u))) -Strict
    & ([scriptblock]::Create((irm $u))) -RulesFile E:\apps-block.txt
    & ([scriptblock]::Create((irm $u))) -Remove
    & ([scriptblock]::Create((irm $u))) -Undo
#>
[CmdletBinding()]
param(
    [string] $RulesUrl  = 'https://raw.githubusercontent.com/VladislavSournine/gb/main/apps-block.txt',
    [string] $RulesFile,
    [switch] $Strict,
    [switch] $AuditOnly,
    [switch] $Remove,
    [switch] $Undo,
    [string] $BackupFile
)

$SidEveryone = 'S-1-1-0'
$SidAdmins   = 'S-1-5-32-544'
$BackupDir   = "$env:ProgramData\GameBlock"

# publishers too broad to block without a product name (would break Windows / browsers / drivers)
$ProtectedPublisherRegex = [regex]'(?i)O=(MICROSOFT|GOOGLE|MOZILLA|ADOBE|INTEL|NVIDIA|ADVANCED MICRO DEVICES|APPLE|ORACLE|ZOOM|LENOVO|HP |DELL|REALTEK|UNITY TECHNOLOGIES|JETBRAINS|PYTHON SOFTWARE)'

# --- pure helpers (unit-tested) -------------------------------------------------

function ConvertFrom-RuleLine {
    <# Parses one rules-file line. Returns $null for blank/comment lines, an object with .Error for bad lines. #>
    param([string] $Line)
    $l = ("$Line" -replace '\s+#.*$', '').Trim()     # whole-line and trailing "  # comment"
    if ($l -eq '' -or $l.StartsWith('#')) { return $null }
    $m = [regex]::Match($l, '^(?i)(publisher|path|appx|allow)\s*:\s*(.+)$')
    if (-not $m.Success) { return [pscustomobject]@{ Error = "unknown rule type: $l"; Line = $l } }
    $type = $m.Groups[1].Value.ToLowerInvariant()
    $value = $m.Groups[2].Value.Trim()

    if ($type -eq 'path' -or $type -eq 'allow') {
        if ($value -notmatch '^(%[A-Z0-9]+%|[A-Za-z]:|\*|\\\\)') { return [pscustomobject]@{ Error = "path must start with %OSDRIVE%, %PROGRAMFILES%, a drive or *: $l"; Line = $l } }
        if ($value -eq '*' -or $value -match '^%OSDRIVE%\\?\*?$') { return [pscustomobject]@{ Error = "path covers the whole disk: $l"; Line = $l } }
        if ($type -eq 'path' -and $value -match '^%(WINDIR|SYSTEM32)%') { return [pscustomobject]@{ Error = "refusing to block Windows itself: $l"; Line = $l } }
        return [pscustomobject]@{ Type = $type; Path = $value; Line = $l; Error = $null }
    }

    $pieces = $value -split '\|', 2
    $publisher = $pieces[0].Trim()
    $product = '*'; if ($pieces.Length -gt 1 -and $pieces[1].Trim()) { $product = $pieces[1].Trim() }
    if ($publisher -notmatch '(?i)(^|,\s*)(O|CN)=') { return [pscustomobject]@{ Error = "publisher must look like 'O=..., C=..': $l"; Line = $l } }
    if ($product -eq '*' -and $ProtectedPublisherRegex.IsMatch($publisher)) {
        return [pscustomobject]@{ Error = "publisher too broad without a product name (would block system apps): $l"; Line = $l }
    }
    return [pscustomobject]@{ Type = $type; Publisher = $publisher; Product = $product; Line = $l; Error = $null }
}

function Get-StableGuid {
    <# Same text -> same rule Id, so re-applying the same list gives an identical policy. #>
    param([string] $Text)
    $md5 = [Security.Cryptography.MD5]::Create()
    try { return [guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).ToString() } finally { $md5.Dispose() }
}

function New-AppLockerPolicyXml {
    <# Builds the AppLocker policy XML from parsed rules. #>
    param([object[]] $Rules, [switch] $Strict, [switch] $AuditOnly)
    $mode = 'Enabled'; if ($AuditOnly) { $mode = 'AuditOnly' }
    $doc = [xml]'<AppLockerPolicy Version="1" />'
    $seen = @{}
    $Rules = @(foreach ($r in $Rules) { if (-not $seen.ContainsKey($r.Line.ToLowerInvariant())) { $seen[$r.Line.ToLowerInvariant()] = 1; $r } })

    function Add-Rule($collection, [string]$kind, [string]$name, [string]$sid, [string]$action, [hashtable]$cond) {
        $r = $doc.CreateElement($kind)
        $r.SetAttribute('Id', (Get-StableGuid "$($collection.GetAttribute('Type'))|$kind|$name|$sid|$action"))
        $r.SetAttribute('Name', $name)
        $r.SetAttribute('Description', 'GameBlock')
        $r.SetAttribute('UserOrGroupSid', $sid)
        $r.SetAttribute('Action', $action)
        $c = $doc.CreateElement('Conditions')
        if ($kind -eq 'FilePathRule') {
            $pc = $doc.CreateElement('FilePathCondition'); $pc.SetAttribute('Path', $cond.Path); [void]$c.AppendChild($pc)
        } else {
            $pc = $doc.CreateElement('FilePublisherCondition')
            $pc.SetAttribute('PublisherName', $cond.Publisher)
            $pc.SetAttribute('ProductName', $cond.Product)
            $pc.SetAttribute('BinaryName', '*')
            $vr = $doc.CreateElement('BinaryVersionRange'); $vr.SetAttribute('LowSection', '*'); $vr.SetAttribute('HighSection', '*')
            [void]$pc.AppendChild($vr); [void]$c.AppendChild($pc)
        }
        [void]$r.AppendChild($c)
        [void]$collection.AppendChild($r)
    }

    # --- EXE collection
    $exe = $doc.CreateElement('RuleCollection'); $exe.SetAttribute('Type', 'Exe'); $exe.SetAttribute('EnforcementMode', $mode)
    [void]$doc.DocumentElement.AppendChild($exe)
    if ($Strict) {
        Add-Rule $exe 'FilePathRule' 'Allow: Windows'        $SidEveryone 'Allow' @{ Path = '%WINDIR%\*' }
        Add-Rule $exe 'FilePathRule' 'Allow: Program Files'  $SidEveryone 'Allow' @{ Path = '%PROGRAMFILES%\*' }
        Add-Rule $exe 'FilePathRule' 'Allow: Administrators' $SidAdmins   'Allow' @{ Path = '*' }
        foreach ($r in $Rules) { if ($r.Type -eq 'allow') { Add-Rule $exe 'FilePathRule' "Allow: $($r.Path)" $SidEveryone 'Allow' @{ Path = $r.Path } } }
    } else {
        Add-Rule $exe 'FilePathRule' 'Allow: everything else' $SidEveryone 'Allow' @{ Path = '*' }
    }
    foreach ($r in $Rules) {
        if ($r.Type -eq 'path')      { Add-Rule $exe 'FilePathRule'      "Block: $($r.Path)"                    $SidEveryone 'Deny' @{ Path = $r.Path } }
        if ($r.Type -eq 'publisher') { Add-Rule $exe 'FilePublisherRule' "Block: $($r.Publisher) | $($r.Product)" $SidEveryone 'Deny' @{ Publisher = $r.Publisher; Product = $r.Product } }
    }

    # --- Packaged apps (Microsoft Store, Settings, Calculator...). ALWAYS present: while Exe rules are
    # enforced and this collection has no rules, Windows blocks every packaged app, even Settings.
    $appx = $doc.CreateElement('RuleCollection'); $appx.SetAttribute('Type', 'Appx'); $appx.SetAttribute('EnforcementMode', $mode)
    [void]$doc.DocumentElement.AppendChild($appx)
    Add-Rule $appx 'FilePublisherRule' 'Allow: all signed packaged apps' $SidEveryone 'Allow' @{ Publisher = '*'; Product = '*' }
    foreach ($r in $Rules) {
        if ($r.Type -eq 'appx') { Add-Rule $appx 'FilePublisherRule' "Block: $($r.Product)" $SidEveryone 'Deny' @{ Publisher = $r.Publisher; Product = $r.Product } }
    }
    return $doc.OuterXml
}

function New-EmptyPolicyXml {
    $doc = [xml]'<AppLockerPolicy Version="1" />'
    foreach ($t in 'Appx', 'Dll', 'Exe', 'Msi', 'Script') {
        $c = $doc.CreateElement('RuleCollection'); $c.SetAttribute('Type', $t); $c.SetAttribute('EnforcementMode', 'NotConfigured')
        [void]$doc.DocumentElement.AppendChild($c)
    }
    return $doc.OuterXml
}

function Get-UndoBackup {
    <# Newest applocker-backup-*.xml in the folder (timestamps in the name sort correctly), or $null. #>
    param([string] $Dir)
    $f = Get-ChildItem -Path $Dir -Filter 'applocker-backup-*.xml' -File -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if ($f) { return $f.FullName }
    return $null
}

function Read-PolicyBackup {
    <# Reads a backup file and checks it really is an AppLocker policy before anything is applied. #>
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Backup file not found: $Path" }
    try { $doc = [xml][IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path)) } catch { throw "Backup is not valid XML: $Path" }
    if ($doc.DocumentElement.Name -ne 'AppLockerPolicy') { throw "Backup is not an AppLocker policy: $Path" }
    return $doc.OuterXml
}

# --- system side ----------------------------------------------------------------

function Get-RulesText {
    if ($RulesFile) { return [IO.File]::ReadAllText((Resolve-Path $RulesFile)) }
    Write-Host "Downloading rules: $RulesUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return (Invoke-WebRequest -Uri $RulesUrl -UseBasicParsing -ErrorAction Stop).Content
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

function Initialize-BackupDir {
    <# Without a locked folder a student could plant a "backup" with an allow-everything policy and wait for -Undo. #>
    Initialize-SecureDir $BackupDir
}

function Set-LocalPolicy {
    param([string] $Xml, [string] $BackupPrefix = 'applocker-backup')
    try {
        $backup = Join-Path $BackupDir ("{0}-{1}.xml" -f $BackupPrefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Get-AppLockerPolicy -Local -Xml | Set-Content -Path $backup -Encoding UTF8
        $a = Get-Acl -LiteralPath $backup; $a.SetOwner([Security.Principal.SecurityIdentifier]::new($SidAdmins)); Set-Acl -LiteralPath $backup -AclObject $a
        Write-Host "Previous policy saved: $backup"
    } catch { Write-Warning "Could not back up the current policy: $($_.Exception.Message)" }

    # fresh random name: nobody can have pre-created (and so own) this file
    $tmp = Join-Path $BackupDir ("applocker-new-{0}.xml" -f [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($tmp, $Xml, [Text.UTF8Encoding]::new($false))
        Set-AppLockerPolicy -XmlPolicy $tmp -ErrorAction Stop
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Enable-AppIdService {
    # AppLocker only enforces rules while the Application Identity service runs.
    # Set-Service can't change this protected service, sc.exe can.
    sc.exe config AppIDSvc start= auto | Out-Null
    Start-Service AppIDSvc -ErrorAction SilentlyContinue
    if ((Get-Service AppIDSvc).Status -ne 'Running') { Write-Warning 'Application Identity service is not running yet; rules apply after a reboot.' }
}

function Invoke-BlockApps {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run PowerShell as Administrator.' }
    $os = (Get-CimInstance Win32_OperatingSystem).Caption
    if ($os -match 'Home') { throw "AppLocker is not available on $os (needs Pro, Education or Enterprise)." }
    Initialize-BackupDir

    if ($Remove) {
        Set-LocalPolicy -Xml (New-EmptyPolicyXml)
        gpupdate /target:computer /force | Out-Null
        Write-Host 'AppLocker rules removed. Programs can run again.' -ForegroundColor Green
        return
    }

    if ($Undo -or $BackupFile) {
        $file = $BackupFile; $prefix = 'applocker-backup'
        if ($Undo) {
            $file = Get-UndoBackup $BackupDir
            if (-not $file) { throw "No AppLocker backup in $BackupDir - nothing to undo." }
            if (-not (Test-TrustedOwner $file)) { throw "Backup $file was not created by an administrator - refusing to apply it. Delete the file and run -Undo again." }
            $prefix = 'applocker-before-undo'   # keeps the current policy, but out of the undo history
        }
        Set-LocalPolicy -Xml (Read-PolicyBackup $file) -BackupPrefix $prefix
        if ($Undo) { Rename-Item -LiteralPath $file -NewName ([IO.Path]::GetFileName($file) -replace '^applocker-backup-', 'applocker-undone-') }
        Enable-AppIdService
        gpupdate /target:computer /force | Out-Null
        Write-Host "AppLocker policy restored from $file" -ForegroundColor Green
        return
    }

    $parsed = @(((Get-RulesText) -split "`r?`n") | ForEach-Object { ConvertFrom-RuleLine $_ } | Where-Object { $_ })
    foreach ($bad in ($parsed | Where-Object { $_.Error })) { Write-Warning "Skipped: $($bad.Error)" }
    $rules = @($parsed | Where-Object { -not $_.Error })
    if (-not $Strict -and @($rules | Where-Object { $_.Type -eq 'allow' }).Count) { Write-Host 'Note: allow: lines are used only with -Strict.' }
    if (@($rules | Where-Object { $_.Type -ne 'allow' }).Count -eq 0 -and -not $Strict) { throw 'No valid rules in the list - nothing to block.' }

    $xml = New-AppLockerPolicyXml -Rules $rules -Strict:$Strict -AuditOnly:$AuditOnly
    Set-LocalPolicy -Xml $xml
    Enable-AppIdService
    gpupdate /target:computer /force | Out-Null

    $what = 'Deny list'; if ($Strict) { $what = 'Strict (only Windows + Program Files)' }
    $how  = 'ENFORCED'; if ($AuditOnly) { $how = 'AUDIT ONLY (nothing blocked, see Event Viewer > AppLocker)' }
    Write-Host "AppLocker: $($rules.Count) block rules, mode: $what, $how." -ForegroundColor Green
    Write-Host 'New launches are checked right away; if a game still starts, sign out or reboot.'
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-BlockApps }
