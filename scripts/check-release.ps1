# Checks the release metadata the workflow relies on:
#   - VERSION holds a plain semver (1.2.3)
#   - RELEASE_NOTES.md starts with "# HomeLAN v<VERSION>"
#   - client/pubspec.yaml, client/lib/version.dart and the server's default Version match VERSION
#   - optionally, a tag (argument, or GITHUB_REF_NAME for a tag build) equals v<VERSION>
# Usage: ./scripts/check-release.ps1 [v1.2.3]
param([string]$Tag)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Read-Text([string]$rel) { Get-Content -LiteralPath (Join-Path $root $rel) -Raw -Encoding UTF8 }

$version = (Read-Text 'VERSION').Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must be a stable semver like 1.2.3, got '$version'"
}

$notes = (Get-Content -LiteralPath (Join-Path $root 'RELEASE_NOTES.md') -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF)
if ($notes -ne "# HomeLAN v$version") {
    throw "RELEASE_NOTES.md must start with '# HomeLAN v$version', got '$notes'"
}

$checks = @(
    @{ File = 'client/pubspec.yaml';                 Pattern = '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$' },
    @{ File = 'client/lib/version.dart';             Pattern = "appVersion\s*=\s*'([^']+)'" },
    @{ File = 'homelan-server/cmd/server/main.go';   Pattern = 'var Version = "([^"]+)"' }
)
foreach ($c in $checks) {
    $m = [regex]::Match((Read-Text $c.File), $c.Pattern)
    if (-not $m.Success) { throw "$($c.File): version not found" }
    if ($m.Groups[1].Value -ne $version) {
        throw "$($c.File) has version $($m.Groups[1].Value), VERSION says $version"
    }
}

if (-not $Tag -and $env:GITHUB_REF_TYPE -eq 'tag') { $Tag = $env:GITHUB_REF_NAME }
if ($Tag -and $Tag -ne "v$version") {
    throw "Tag $Tag does not match v$version"
}

Write-Host "Release metadata OK: v$version$(if ($Tag) { " ($Tag)" })"
