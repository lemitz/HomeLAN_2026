# Creates the Android release keystore once and stores it in the repository secrets, so every
# release APK is signed with the same key and installs over the previous one.
#
# Needs: keytool (comes with any JDK) and the GitHub CLI (gh auth login).
# Usage: ./scripts/make-keystore.ps1 [-Repo lemitz/HomeLAN_2026] [-Out ~/homelan-release.jks]
#
# KEEP THE .jks FILE AND THE PASSWORD SAFE. If the key is lost, the next APK cannot update the
# installed app: every user would have to uninstall it (and lose the local cache) first.
param(
    [string]$Repo = 'lemitz/HomeLAN_2026',
    [string]$Out = (Join-Path $HOME 'homelan-release.jks'),
    [string]$Alias = 'homelan'
)

$ErrorActionPreference = 'Stop'

if (Test-Path $Out) { throw "$Out already exists. Delete it yourself if you really want a new key." }
$keytool = (Get-Command keytool -ErrorAction SilentlyContinue).Source
if (-not $keytool -and $env:JAVA_HOME) { $keytool = Join-Path $env:JAVA_HOME 'bin/keytool' }
if (-not $keytool) { throw 'keytool not found: install a JDK or set JAVA_HOME' }
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = 'C:\Program Files\GitHub CLI\gh.exe' }

# 32 random characters from a URL-safe alphabet.
$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'B')

& $keytool -genkeypair -v -keystore $Out -storetype PKCS12 -alias $Alias -keyalg RSA -keysize 4096 `
    -validity 10000 -storepass $password -keypass $password -dname 'CN=HomeLAN, O=lemitz'
if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Out))
# --body, not a pipe: PowerShell appends a newline to piped strings.
foreach ($s in @(@('HOMELAN_KEYSTORE_BASE64', $b64), @('HOMELAN_KEYSTORE_PASSWORD', $password),
        @('HOMELAN_KEY_PASSWORD', $password), @('HOMELAN_KEY_ALIAS', $Alias))) {
    & $gh secret set $s[0] -R $Repo --body $s[1]
    if ($LASTEXITCODE -ne 0) { throw "gh secret set $($s[0]) failed" }
}

# The password next to the key, so the backup is complete. Move both somewhere safe.
Set-Content -LiteralPath "$Out.password.txt" -Value $password -NoNewline

Write-Host ""
Write-Host "Keystore: $Out"
Write-Host "Password: $password"
Write-Host "Secrets HOMELAN_KEYSTORE_BASE64 / _PASSWORD / HOMELAN_KEY_ALIAS / HOMELAN_KEY_PASSWORD are set in $Repo."
Write-Host "Back up the keystore file and the password somewhere safe."
