<#
.SYNOPSIS
  Used by the GitHub Action "Add games": appends AppLocker rules from an issue to apps-block.txt.

.DESCRIPTION
  Takes the rules pasted into the "Додати ігри" issue form (lines from apps-block-<PC>.txt made by
  find-games.ps1), checks every rule with the same parser block-apps.ps1 uses, drops rules that are
  already in the list, and appends the rest. If any rule is invalid, nothing is changed.

  Env: ISSUE_BODY, ISSUE_NUMBER, GITHUB_OUTPUT. Writes the reply for the issue to $env:RUNNER_TEMP/reply.md.
#>

. "$PSScriptRoot/../block-apps.ps1"

function Get-PastedLines {
    <# Issue forms put a "render: text" field inside ``` fences; returns the lines inside them. #>
    param([string] $Body)
    $inside = $false
    foreach ($line in ("$Body" -split "\r?\n")) {
        if ($line.Trim().StartsWith('```')) { $inside = -not $inside; continue }
        if ($inside) { $line }
    }
}

function Add-IssueRules {
    <# Returns @{ Text = new file text or $null; Added; Skipped; Errors }. #>
    param([string] $Existing, [string] $Body, [int] $Issue)
    $key = { param($r) "$($r.Line)".ToLowerInvariant() -replace '\s+', ' ' }
    $known = @{}
    foreach ($l in ($Existing -split "\r?\n")) { $r = ConvertFrom-RuleLine $l; if ($r -and -not $r.Error) { $known[(& $key $r)] = 1 } }

    $errors = @(); $out = @(); $comments = @(); $added = 0; $skipped = 0
    foreach ($l in Get-PastedLines $Body) {
        $t = $l.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) { $comments += $t; continue }
        $r = ConvertFrom-RuleLine $t
        if ($r.Error) { $errors += $r.Error; continue }
        $k = & $key $r
        if ($known.ContainsKey($k)) { $skipped++; $comments = @(); continue }   # its comment goes too
        $known[$k] = 1; $added++
        $out += $comments + $r.Line + ''; $comments = @()
    }
    if ($errors.Count -or -not $added) { return @{ Text = $null; Added = $added; Skipped = $skipped; Errors = $errors } }
    $text = $Existing.TrimEnd() + "`n`n# --- issue #$Issue ---`n" + (($out -join "`n").TrimEnd()) + "`n"
    return @{ Text = $text; Added = $added; Skipped = $skipped; Errors = @() }
}

function Format-Reply {
    param($Result)
    if ($Result.Errors.Count) {
        return "Нічого не додано: є помилки. Виправ і створи нове issue.`n`n" + (($Result.Errors | ForEach-Object { "- ``$_``" }) -join "`n")
    }
    if (-not $Result.Added) { return "Нічого нового: усі правила ($($Result.Skipped)) вже є в apps-block.txt." }
    return "Додано правил: $($Result.Added), вже були: $($Result.Skipped).`n`nЗастосуй на кожному ПК: ``gb apps``"
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $file = "$PSScriptRoot/../apps-block.txt"
    $result = Add-IssueRules -Existing ([IO.File]::ReadAllText($file)) -Body $env:ISSUE_BODY -Issue ([int]$env:ISSUE_NUMBER)
    if ($result.Text) { [IO.File]::WriteAllText($file, $result.Text, [Text.UTF8Encoding]::new($false)) }
    [IO.File]::WriteAllText("$env:RUNNER_TEMP/reply.md", (Format-Reply $result))
    "changed=$([bool]$result.Text)".ToLower() | Add-Content $env:GITHUB_OUTPUT
    "ok=$(-not $result.Errors.Count)".ToLower() | Add-Content $env:GITHUB_OUTPUT
}
