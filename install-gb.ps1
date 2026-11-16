<#
.SYNOPSIS
    Installs the short "gb" command on a Windows PC (once per PC, PowerShell as Administrator):
    irm https://raw.githubusercontent.com/VladislavSournine/gb/main/install-gb.ps1 | iex
.DESCRIPTION
    Puts gb.ps1 into C:\Program Files\SysTools and gb.cmd into C:\Windows (already on PATH).
    Both folders are writable only by administrators, so a student cannot swap the files.
    gb.cmd starts PowerShell with -ExecutionPolicy Bypass, so no execution policy change is needed.
    Re-running the installer updates gb.ps1.
#>

$RepoBase   = 'https://raw.githubusercontent.com/VladislavSournine/gb/main'
$InstallDir = "$env:ProgramFiles\SysTools"
$ShimPath   = "$env:SystemRoot\gb.cmd"

function Get-CmdShim {
    param([string] $Ps1Path)
    return "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Ps1Path`" %*"
}

function Install-Gb {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run PowerShell as Administrator.' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $ps1 = "$InstallDir\gb.ps1"
    Invoke-WebRequest -Uri "$RepoBase/gb.ps1" -UseBasicParsing -OutFile $ps1 -ErrorAction Stop
    [IO.File]::WriteAllText($ShimPath, (Get-CmdShim $ps1) + "`r`n", [Text.Encoding]::ASCII)

    Write-Host 'Installed. Open PowerShell as Administrator and type:  gb' -ForegroundColor Green
}

# Run unless dot-sourced (tests dot-source the file to load the functions only).
if ($MyInvocation.InvocationName -ne '.') { Install-Gb }
