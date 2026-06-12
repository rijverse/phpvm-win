# install.ps1 - phpvm-windows installer
# Idempotent. Safe to re-run. No admin required.

[CmdletBinding()]
param(
    [switch]$Upgrade,
    [switch]$Silent,
    [string]$Prefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Choice {
    param([string]$Prompt, [bool]$DefaultYes = $true, [switch]$AlwaysYes)
    if ($AlwaysYes) { return $true }
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Prompt $suffix"
    if (-not $ans) { return $DefaultYes }
    return ($ans -match '^[Yy]')
}

if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    throw "phpvm: PowerShell 5.1 or newer required. Got $($PSVersionTable.PSVersion)."
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw "phpvm: PowerShell Constrained Language Mode detected - cannot install."
}

# Source layout: when run from a clone we're at repo root; when piped via `irm | iex`
# the script content needs a fallback (clone repo first).
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'phpvm.ps1'))) {
    $srcRoot = $PSScriptRoot
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "phpvm: install.ps1 was piped (no local source). git is required to fetch the repo."
    }
    $repoUrl = if ($env:PHPVM_REPO) { $env:PHPVM_REPO } else { 'https://github.com/rijverse/phpvm-win' }
    $srcRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-src-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    Write-Host "phpvm: cloning $repoUrl -> $srcRoot"
    & git clone --depth 1 $repoUrl $srcRoot 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "phpvm: clone failed" }
}

$installRoot = if ($Prefix) { $Prefix } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phpvm' }
$binDir  = Join-Path $installRoot 'bin'
$shimDir = Join-Path $installRoot 'shim'

Write-Host "phpvm: installing to $installRoot"

# Execution policy nudge
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -in @('Restricted', 'AllSigned')) {
    if ($Silent -or (Read-Choice "phpvm: CurrentUser execution policy is $policy. Set to RemoteSigned?" $true)) {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    }
}

# Directories
foreach ($d in @($installRoot, $binDir, $shimDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

# Copy phpvm.ps1, lib/*, uninstall.ps1 -> bin
$payload = @(
    @{ Src = 'phpvm.ps1';     Dest = $binDir }
    @{ Src = 'uninstall.ps1'; Dest = $binDir }
    @{ Src = 'lib';           Dest = $binDir }
)
foreach ($p in $payload) {
    $srcPath = Join-Path $srcRoot $p.Src
    if (-not (Test-Path -LiteralPath $srcPath)) {
        throw "phpvm: source missing: $srcPath"
    }
    Copy-Item -LiteralPath $srcPath -Destination $p.Dest -Recurse -Force
}

# Hook file goes one level up
$hookSrc  = Join-Path $srcRoot 'profile\phpvm-hook.ps1'
$hookDest = Join-Path $installRoot 'profile-hook.ps1'
Copy-Item -LiteralPath $hookSrc -Destination $hookDest -Force

# phpvm.cmd wrapper so `phpvm` works in cmd.exe too
$cmdWrapper = Join-Path $binDir 'phpvm.cmd'
$cmdContent = @(
    '@echo off'
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phpvm.ps1" %*'
) -join "`r`n"
Set-Content -LiteralPath $cmdWrapper -Value $cmdContent -Encoding ASCII -NoNewline

# install.meta - version comes from phpvm.ps1 so the two never drift
$cliVersion = '0.0.0'
$cliRaw = Get-Content -LiteralPath (Join-Path $srcRoot 'phpvm.ps1') -Raw
if ($cliRaw -match "PhpvmVersion\s*=\s*'([^']+)'") { $cliVersion = $matches[1] }
$metaFile = Join-Path $installRoot 'install.meta'
$metaLines = @(
    "version=$cliVersion"
    "installed_at=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    "src=$srcRoot"
)
if ($env:PHPVM_REPO) { $metaLines += "repo=$env:PHPVM_REPO" }
Set-Content -LiteralPath $metaFile -Value $metaLines -Encoding UTF8

# PATH update - user scope, idempotent. Goes through the registry directly:
# [Environment]::GetEnvironmentVariable returns the EXPANDED value and Set writes
# REG_SZ, so a read-modify-write through it would permanently flatten any
# %VAR%-style entries other tools keep in the user PATH.
function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if (-not $key) { return '' }
    try {
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { $key.Close() }
}

function Set-UserPathRaw {
    param([string]$Value)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
}

function Update-UserPath {
    param([string[]]$Prepend)
    $existing = @((Get-UserPathRaw) -split ';' | Where-Object { $_ })
    $expandedLower = @{}
    foreach ($e in $existing) {
        $expandedLower[[Environment]::ExpandEnvironmentVariables($e).TrimEnd('\').ToLowerInvariant()] = $true
    }

    $toAdd = @()
    foreach ($p in $Prepend) {
        if (-not $expandedLower.ContainsKey($p.TrimEnd('\').ToLowerInvariant())) {
            $toAdd += $p
        }
    }
    if ($toAdd.Count -eq 0) { return $false }

    Set-UserPathRaw -Value ((@($toAdd) + $existing) -join ';')
    return $true
}

# A non-default prefix is invisible to the runtime (shim, hook, CLI all default
# to ~\.phpvm), so it must be persisted as PHPVM_ROOT - they all honor that.
if ($Prefix) {
    [Environment]::SetEnvironmentVariable('PHPVM_ROOT', $installRoot, 'User')
    $env:PHPVM_ROOT = $installRoot
    Write-Host "phpvm: persisted PHPVM_ROOT=$installRoot (user env var)."
}

$pathChanged = Update-UserPath -Prepend @($binDir, $shimDir)
if ($pathChanged) {
    Write-Host "phpvm: user PATH updated."
} else {
    Write-Host "phpvm: PATH already includes phpvm dirs."
}

# Refresh current session
$env:Path = ($binDir + ';' + $shimDir + ';' + $env:Path)

# Broadcast WM_SETTINGCHANGE so Explorer-spawned shells refresh
try {
    if (-not ('PhpvmInstaller.NativeMethods' -as [Type])) {
        Add-Type -Namespace PhpvmInstaller -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
"@
    }
    $result = [System.UIntPtr]::Zero
    [PhpvmInstaller.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result
    ) | Out-Null
} catch {
    Write-Warning "phpvm: WM_SETTINGCHANGE broadcast failed (non-fatal): $($_.Exception.Message)"
}

# Optional setup steps
if (-not $Upgrade) {
    $alwaysYes = [bool]$Silent
    if (Read-Choice "phpvm: enable auto-switch hook now?" $true -AlwaysYes:$alwaysYes) {
        $installedCli = Join-Path $binDir 'phpvm.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installedCli '--enable-hook'
    }

    if (Read-Choice "phpvm: scan for PHP and set an initial active version?" $true -AlwaysYes:$alwaysYes) {
        $installedCli = Join-Path $binDir 'phpvm.ps1'
        Write-Host ''
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installedCli '--list'
        Write-Host ''
        Write-Host "Run 'phpvm --set <version>' to choose one, or just 'phpvm' for the TUI picker."
    }
}

Write-Host ''
Write-Host "phpvm: install complete."
Write-Host "Open a new PowerShell or cmd window to pick up PATH changes."
