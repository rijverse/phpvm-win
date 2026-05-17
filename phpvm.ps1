# phpvm.ps1 — main CLI entry
# Mirrors flag surface of upstream bash phpvm (per-project PHP version mgr).

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RawArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PhpvmVersion = '1.0.0'

$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'detect.ps1')
. (Join-Path $libRoot 'switch.ps1')
. (Join-Path $libRoot 'project.ps1')
. (Join-Path $libRoot 'tui.ps1')
. (Join-Path $libRoot 'doctor.ps1')

# --- helpers ---------------------------------------------------------------

function Show-Help {
    @"
phpvm $($script:PhpvmVersion) — per-project PHP version manager for Windows.

USAGE
  phpvm                          launch TUI picker
  phpvm --list, -l               list installed PHP versions
  phpvm --current, -c            show active version + 'php --version'
  phpvm --set <ver>, -s <ver>    switch active PHP
  phpvm --auto [--quiet] [--print] [dir]
                                 auto-switch from .php-version or composer.json
  phpvm --set-project <ver>, -p <ver>
                                 write .php-version in current dir
  phpvm --enable-hook            install auto-switch hook in PowerShell profile
  phpvm --disable-hook           remove auto-switch hook
  phpvm --doctor                 diagnose install
  phpvm --self-update [URL] [REF]
                                 pull from git, re-run installer
  phpvm --uninstall              run uninstall.ps1
  phpvm --version, -v            print version
  phpvm --help, -h               this help

ENV
  PHPVM_SEARCH_PATHS    semicolon-separated globs for extra PHP discovery
  PHPVM_REPO            git URL used by --self-update
  PHPVM_NO_TUI          disable TUI (force --list / --set workflow)
  NO_COLOR              disable ANSI colors
"@
}

function Format-ColorIfTty {
    param([string]$Text, [string]$Ansi)
    if ($env:NO_COLOR -or -not $Host.UI.SupportsVirtualTerminal) { return $Text }
    "$([char]27)[$Ansi`m$Text$([char]27)[0m"
}

# --- command implementations ----------------------------------------------

function Show-VersionList {
    $items = Get-AllPhpInstalls
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "phpvm: no PHP installations found."
        return
    }
    foreach ($i in $items) {
        $marker = if ($i.Active) { '*' } else { ' ' }
        $line = "{0} {1,-8} {2,-8} {3}" -f $marker, $i.Version, $i.Source, $i.Dir
        if ($i.Active) { Write-Host (Format-ColorIfTty $line '1;32') }
        else           { Write-Host $line }
    }
}

function Show-Current {
    $active = Get-ActivePhpInstall
    if (-not $active) {
        Write-Host "phpvm: no active PHP."
        return 1
    }
    Write-Host "PHP $($active.Version)  ($($active.Source) — $($active.Dir))"
    & $active.Path '-v'
    return 0
}

function Invoke-Auto {
    param(
        [string]$Dir,
        [switch]$Quiet,
        [switch]$Print
    )
    if (-not $Dir) { $Dir = (Get-Location).Path }
    $installs = Get-AllPhpInstalls
    $proj = Resolve-ProjectPhpQuery -StartDir $Dir -Installs $installs
    if (-not $proj) {
        if (-not $Quiet) { Write-Host "phpvm: no project PHP requirement found." }
        return 0
    }
    $target = Find-PhpInstallByQuery -Query $proj.Query -Installs $installs
    if (-not $target) {
        if (-not $Quiet) {
            Write-Host "phpvm: project wants $($proj.Query) (from $($proj.Source)) but no matching install."
        }
        return 1
    }
    $active = Get-ActivePhpInstall -Installs $installs
    if ($active -and $active.Path -eq $target.Path) {
        if ($Print -and -not $Quiet) {
            Write-Host "phpvm: already on $($target.Version)"
        }
        return 0
    }
    Set-PhpvmActive -Install $target -Quiet:$Quiet
    if ($Print -and -not $Quiet) {
        Write-Host "phpvm: $($target.Version) (from $($proj.Source))"
    }
    return 0
}

function Enable-Hook {
    $hookSrc = Join-Path (Get-PhpvmRoot) 'profile-hook.ps1'
    if (-not (Test-Path -LiteralPath $hookSrc)) {
        # During dev / pre-install, copy from repo profile dir
        $repoHook = Join-Path $PSScriptRoot 'profile\phpvm-hook.ps1'
        if (Test-Path -LiteralPath $repoHook) {
            Initialize-PhpvmDirs
            Copy-Item -LiteralPath $repoHook -Destination $hookSrc -Force
        } else {
            throw "phpvm: hook source missing at $hookSrc and $repoHook"
        }
    }

    $sentinel = '# phpvm auto-switch'
    $line = ". `"$hookSrc`"  $sentinel"

    $profileTargets = @($PROFILE.CurrentUserAllHosts)
    # PS 5.1 vs 7 split — also write the other host's profile if it differs
    if ($PROFILE.CurrentUserCurrentHost -and ($PROFILE.CurrentUserCurrentHost -ne $PROFILE.CurrentUserAllHosts)) {
        $profileTargets += $PROFILE.CurrentUserCurrentHost
    }

    foreach ($p in $profileTargets) {
        $dir = Split-Path -Parent $p
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $existing = if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } else { '' }
        if ($existing -match [regex]::Escape($sentinel)) {
            Write-Host "phpvm: hook already present in $p"
            continue
        }
        Add-Content -LiteralPath $p -Value "`r`n$line`r`n"
        Write-Host "phpvm: hook added to $p"
    }
    Write-Host "phpvm: open a new PowerShell to activate the hook."
}

function Disable-Hook {
    $sentinel = '# phpvm auto-switch'
    $profileTargets = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($p in $profileTargets) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $lines = Get-Content -LiteralPath $p
        $filtered = $lines | Where-Object { $_ -notmatch [regex]::Escape($sentinel) }
        if ($filtered.Count -eq $lines.Count) {
            Write-Host "phpvm: no hook line in $p"
            continue
        }
        $backup = "$p.phpvm-backup"
        Copy-Item -LiteralPath $p -Destination $backup -Force
        Set-Content -LiteralPath $p -Value $filtered -Encoding UTF8
        Write-Host "phpvm: hook removed from $p (backup: $backup)"
    }
}

function Invoke-SelfUpdate {
    param([string]$Url, [string]$Ref)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "phpvm: git required for --self-update. Install via 'scoop install git' or git-scm.com."
    }

    if (-not $Url) {
        $metaFile = Join-Path (Get-PhpvmRoot) 'install.meta'
        if (Test-Path -LiteralPath $metaFile) {
            foreach ($line in Get-Content -LiteralPath $metaFile) {
                if ($line -match '^repo=(.+)$') { $Url = $matches[1].Trim() }
            }
        }
        if (-not $Url) { $Url = $env:PHPVM_REPO }
    }
    if (-not $Url) {
        throw "phpvm: no repo URL. Pass one or set PHPVM_REPO."
    }
    if (-not $Ref) { $Ref = 'main' }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Write-Host "phpvm: cloning $Url@$Ref → $tmp"
        & git clone --depth 1 --branch $Ref $Url $tmp 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "phpvm: git clone failed" }
        $installer = Join-Path $tmp 'install.ps1'
        if (-not (Test-Path -LiteralPath $installer)) { throw "phpvm: install.ps1 missing in clone" }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer --upgrade
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Uninstall {
    $script = Join-Path $PSScriptRoot 'uninstall.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        $script = Join-Path (Join-Path (Get-PhpvmRoot) 'bin') 'uninstall.ps1'
    }
    if (-not (Test-Path -LiteralPath $script)) {
        throw "phpvm: uninstall.ps1 not found."
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script
}

# --- arg parse + dispatch -------------------------------------------------

if (-not $RawArgs -or $RawArgs.Count -eq 0) {
    Invoke-PhpvmTui
    exit 0
}

$cmd = $RawArgs[0]
$rest = if ($RawArgs.Count -gt 1) { $RawArgs[1..($RawArgs.Count - 1)] } else { @() }

switch -Regex ($cmd) {
    '^(--help|-h)$'     { Show-Help; exit 0 }
    '^(--version|-v)$'  { Write-Host "phpvm $($script:PhpvmVersion)"; exit 0 }
    '^(--list|-l)$'     { Show-VersionList; exit 0 }
    '^(--current|-c)$'  { exit (Show-Current) }

    '^(--set|-s)$' {
        if ($rest.Count -lt 1) { throw "phpvm: --set requires a version argument" }
        Switch-PhpvmTo -Query $rest[0] | Out-Null
        exit 0
    }

    '^(--set-project|-p)$' {
        if ($rest.Count -lt 1) { throw "phpvm: --set-project requires a version argument" }
        $f = Write-PhpVersionFile -Version $rest[0]
        Write-Host "phpvm: wrote $f"
        exit 0
    }

    '^(--auto|-a)$' {
        $quiet = $false; $print = $false; $dir = $null
        foreach ($a in $rest) {
            switch ($a) {
                '--quiet' { $quiet = $true }
                '--print' { $print = $true }
                default {
                    if (-not $dir) { $dir = $a } else { throw "phpvm: unexpected arg '$a' to --auto" }
                }
            }
        }
        exit (Invoke-Auto -Dir $dir -Quiet:$quiet -Print:$print)
    }

    '^--enable-hook$'  { Enable-Hook; exit 0 }
    '^--disable-hook$' { Disable-Hook; exit 0 }
    '^--doctor$'       { exit (Invoke-PhpvmDoctor) }
    '^--uninstall$'    { Invoke-Uninstall; exit 0 }

    '^--self-update$' {
        $url = if ($rest.Count -gt 0) { $rest[0] } else { $null }
        $ref = if ($rest.Count -gt 1) { $rest[1] } else { $null }
        Invoke-SelfUpdate -Url $url -Ref $ref
        exit 0
    }

    '^--window$' {
        Write-Host "phpvm: --window not implemented yet (planned for v2)."
        exit 2
    }

    default {
        Write-Host "phpvm: unknown command '$cmd'"
        Show-Help
        exit 2
    }
}
