# phpvm.ps1 - main CLI entry
# Mirrors flag surface of upstream bash phpvm (per-project PHP version mgr).

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RawArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PhpvmVersion = '2.0.0'

$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'detect.ps1')
. (Join-Path $libRoot 'switch.ps1')
. (Join-Path $libRoot 'project.ps1')
. (Join-Path $libRoot 'install-php.ps1')
. (Join-Path $libRoot 'tui.ps1')
. (Join-Path $libRoot 'doctor.ps1')
. (Join-Path $libRoot 'gui.ps1')

# --- helpers ---------------------------------------------------------------

function Show-Help {
    @"
phpvm $($script:PhpvmVersion) - per-project PHP version manager for Windows.

USAGE
  phpvm                          launch TUI picker
  phpvm --list, -l               list installed PHP versions
  phpvm --list --paths           list with absolute php.exe paths
  phpvm --list --json            list as JSON ([{version,path,active}])
  phpvm which <ver>              print the php.exe path for a version
  phpvm install <ver> [--print] [--force]
                                 download + install NTS x64 PHP (minor or 'latest')
  phpvm --current, -c            show effective version + shell/project/global layers
  phpvm global <ver>             set the global default PHP (alias: --set, -s)
  phpvm local <ver>              pin this dir via .php-version (alias: --set-project, -p)
  phpvm shell <ver>              pin PHP for THIS terminal only (needs the hook)
  phpvm shell --unset            remove this terminal's pin
  phpvm --auto [--quiet] [--print] [dir]
                                 resolve project PHP from .php-version or composer.json
  phpvm --enable-hook            install auto-switch hook + wrapper in PowerShell profile
  phpvm --disable-hook           remove auto-switch hook
  phpvm --window                 launch the system-tray GUI (alias: --tray)
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
    param([switch]$Paths, [switch]$Json)
    $items = Get-AllPhpInstalls
    if ($Json) {
        Write-Output (ConvertTo-PhpInstallsJson -Installs $items)
        return
    }
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "phpvm: no PHP installations found."
        return
    }
    foreach ($i in $items) {
        $marker = if ($i.Active) { '*' } else { ' ' }
        $col = if ($Paths) { $i.Path } else { $i.Dir }
        $line = "{0} {1,-8} {2,-8} {3}" -f $marker, $i.Version, $i.Source, $col
        if ($i.Active) { Write-Host (Format-ColorIfTty $line '1;32') }
        else           { Write-Host $line }
    }
}

function Show-Current {
    $installs = Get-AllPhpInstalls

    $shell = $env:PHPVM_SHELL_VERSION
    $project = $env:PHPVM_AUTO_VERSION
    if (-not $project) {
        # Hook may not have run (or no hook). Resolve the project from cwd.
        $proj = Resolve-ProjectPhpQuery -StartDir (Get-Location).Path -Installs $installs
        if ($proj) {
            $pt = Find-PhpInstallByQuery -Query $proj.Query -Installs $installs
            if ($pt) { $project = $pt.Minor }
        }
    }
    $meta = Get-PhpvmActiveMeta
    $global = if ($meta -and $meta.ContainsKey('minor')) { $meta['minor'] } else { $null }

    $effective = Resolve-PhpvmEffectiveMinor -Shell $shell -Project $project -Global $global
    if (-not $effective) {
        Write-Host "phpvm: no active PHP. Run 'phpvm global <ver>'."
        return 1
    }

    $eff = Find-PhpInstallByQuery -Query $effective -Installs $installs
    if ($eff) {
        Write-Host "Effective PHP: $($eff.Version)  ($($eff.Source) - $($eff.Dir))"
    } else {
        Write-Host "Effective PHP: $effective  (not registered - run 'phpvm --list')"
    }

    $shellStr = if ($shell)   { $shell }   else { '(unset)' }
    $projStr  = if ($project) { $project } else { '(none)' }
    $globStr  = if ($global)  { $global }  else { '(none)' }
    Write-Host "  shell   : $shellStr"
    Write-Host "  project : $projStr"
    Write-Host "  global  : $globStr"

    $status = Get-PhpvmShimStatus
    if ($status -eq 'shadowed') {
        Write-Host "phpvm: note - another php.exe shadows the shim on PATH. Run 'phpvm --doctor'."
    } elseif ($status -eq 'absent') {
        Write-Host "phpvm: note - shim not written yet. Run 'phpvm global <ver>'."
    }

    if ($eff) {
        $v = & $eff.Path '-v' 2>$null | Select-Object -First 1
        if ($v) { Write-Host $v }
    }
    return 0
}

function Invoke-Auto {
    # Work out a directory's project PHP. Doesn't switch anything - with --print it
    # just echoes the minor for the cd-hook to stash in PHPVM_AUTO_VERSION.
    param(
        [string]$Dir,
        [switch]$Quiet,
        [switch]$Print
    )
    if (-not $Dir) { $Dir = (Get-Location).Path }
    $installs = Get-AllPhpInstalls
    $proj = Resolve-ProjectPhpQuery -StartDir $Dir -Installs $installs
    if (-not $proj) {
        if (-not $Quiet -and -not $Print) { Write-Host "phpvm: no project PHP requirement found." }
        return
    }
    $target = Find-PhpInstallByQuery -Query $proj.Query -Installs $installs
    if (-not $target) {
        if (-not $Quiet -and -not $Print) {
            Write-Host "phpvm: project wants $($proj.Query) (from $($proj.Source)) but no matching install."
        }
        return
    }
    # make sure the junction + shim exist so PHPVM_AUTO_VERSION resolves later.
    # this runs from the prompt, so swallow anything that goes wrong.
    try {
        Register-PhpvmVersion -Install $target | Out-Null
        Write-PhpvmResolverShim | Out-Null
    } catch { }

    if ($Print) {
        # only the minor goes to stdout - that's what the hook reads. anything
        # else would have to be Write-Host so it doesn't end up in the capture.
        Write-Output $target.Minor
    } elseif (-not $Quiet) {
        Write-Host "phpvm: project wants PHP $($target.Minor) (from $($proj.Source))"
    }
}

function Get-PhpvmHookProfileTargets {
    # CurrentUserAllHosts for BOTH editions. $PROFILE only describes the edition
    # running this script - and phpvm.cmd always launches Windows PowerShell, so
    # relying on it would leave pwsh (Documents\PowerShell) without the hook.
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $targets = @(
        (Join-Path $docs 'WindowsPowerShell\profile.ps1')
        (Join-Path $docs 'PowerShell\profile.ps1')
    )
    if ($PROFILE.CurrentUserAllHosts) { $targets += $PROFILE.CurrentUserAllHosts }
    return @($targets | Sort-Object -Unique)
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

    foreach ($p in Get-PhpvmHookProfileTargets) {
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
    # Scrub both editions' AllHosts profiles plus the host-specific files older
    # phpvm versions wrote ($PROFILE.CurrentUserCurrentHost of the running edition).
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $profileTargets = @(
        Get-PhpvmHookProfileTargets
        (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
        (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
        $PROFILE.CurrentUserCurrentHost
    ) | Where-Object { $_ } | Sort-Object -Unique
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
        # install.meta only records repo= for PHPVM_REPO installs; default installs
        # come from the canonical repo, so fall back to it instead of giving up.
        $Url = 'https://github.com/rijverse/phpvm-win'
    }
    if (-not $Ref) { $Ref = 'main' }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-update-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Write-Host "phpvm: cloning $Url@$Ref -> $tmp"
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
$rest = @(if ($RawArgs.Count -gt 1) { $RawArgs[1..($RawArgs.Count - 1)] } else { @() })

switch -Regex ($cmd) {
    '^(--help|-h)$'     { Show-Help; exit 0 }
    '^(--version|-v)$'  { Write-Host "phpvm $($script:PhpvmVersion)"; exit 0 }

    '^(--list|-l)$' {
        $paths = $false; $json = $false
        foreach ($a in $rest) {
            switch ($a) {
                '--paths' { $paths = $true }
                '--json'  { $json = $true }
                default { throw "phpvm: unknown --list option '$a'" }
            }
        }
        Show-VersionList -Paths:$paths -Json:$json
        exit 0
    }

    '^(--current|-c)$'  { exit (Show-Current) }

    '^which$' {
        if ($rest.Count -lt 1) { throw "phpvm: which requires a version argument" }
        $p = Resolve-PhpvmWhich -Query $rest[0]
        if (-not $p) {
            [Console]::Error.WriteLine("phpvm: no PHP matching '$($rest[0])'.")
            exit 1
        }
        Write-Output $p
        exit 0
    }

    '^(--set|-s|global)$' {
        if ($rest.Count -lt 1) { throw "phpvm: '$cmd' requires a version argument" }
        Switch-PhpvmTo -Query $rest[0] | Out-Null
        exit 0
    }

    '^(--set-project|-p|local)$' {
        if ($rest.Count -lt 1) { throw "phpvm: '$cmd' requires a version argument" }
        $f = Write-PhpVersionFile -Version $rest[0]
        Write-Host "phpvm: wrote $f"
        exit 0
    }

    '^install$' {
        $print = $false; $force = $false; $ver = $null
        foreach ($a in $rest) {
            switch ($a) {
                '--print' { $print = $true }
                '--force' { $force = $true }
                default {
                    if (-not $ver) { $ver = $a } else { throw "phpvm: unexpected arg '$a' to install" }
                }
            }
        }
        if (-not $ver) { throw "phpvm: install requires a version (e.g. 8.3 or latest)" }
        Install-Php -Query $ver -Print:$print -Force:$force
        exit 0
    }

    '^sh-shell$' {
        # Hidden verb used by the profile 'phpvm' wrapper. Validates + registers
        # the version, prints the bare minor on stdout for the wrapper to capture.
        if ($rest.Count -lt 1) { [Console]::Error.WriteLine("phpvm: sh-shell requires a version"); exit 1 }
        $t = Resolve-PhpvmShellTarget -Query $rest[0]
        if (-not $t) {
            [Console]::Error.WriteLine("phpvm: no installed PHP matches '$($rest[0])'.")
            exit 1
        }
        Write-Output $t.Minor
        exit 0
    }

    '^shell$' {
        # Reaching here means the profile wrapper is not active (it intercepts
        # 'shell' in-session). Per-terminal env cannot be set from this subprocess.
        Write-Host "phpvm: per-shell pinning needs the profile wrapper function."
        Write-Host "       Run 'phpvm --enable-hook', open a new PowerShell, then 'phpvm shell <ver>'."
        exit 2
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
        Invoke-Auto -Dir $dir -Quiet:$quiet -Print:$print
        exit 0
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

    '^(--window|--tray)$' {
        exit (Invoke-PhpvmTray)
    }

    default {
        Write-Host "phpvm: unknown command '$cmd'"
        Show-Help
        exit 2
    }
}
