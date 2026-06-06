# lib/switch.ps1 - resolver shim + per-version junctions + active state mgmt
# Model (matches Linux phpvm v2.5.0+): the shim php.cmd is a static resolver that
# picks a version at call time from three layers, highest priority first:
#   1. shell   - %PHPVM_SHELL_VERSION% (per terminal, set by `phpvm shell`)
#   2. project - %PHPVM_AUTO_VERSION%  (per terminal, set by the cd-hook)
#   3. global  - minor= in shim\.active (the persisted default)
# Each layer is a minor (e.g. 8.2) resolved to versions\<minor>\php.exe, where
# versions\<minor> is a directory junction to the real install. Junctions need no
# admin rights, unlike symlinks.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'detect.ps1')

function New-PhpvmResolverShimContent {
    # Static resolver. No PowerShell spawn: pure cmd + a junction lookup so `php`
    # startup stays fast. The layered lookup mirrors the three resolution layers.
    @(
        '@echo off'
        'setlocal'
        'if not defined PHPVM_ROOT set "PHPVM_ROOT=%USERPROFILE%\.phpvm"'
        'set "VER=%PHPVM_SHELL_VERSION%"'
        'if not defined VER set "VER=%PHPVM_AUTO_VERSION%"'
        'if not defined VER if exist "%PHPVM_ROOT%\shim\.active" for /f "usebackq tokens=2 delims==" %%v in (`findstr /b "minor=" "%PHPVM_ROOT%\shim\.active"`) do set "VER=%%v"'
        'if not defined VER goto :phpvm_noactive'
        'if not exist "%PHPVM_ROOT%\versions\%VER%\php.exe" goto :phpvm_notreg'
        'endlocal & "%PHPVM_ROOT%\versions\%VER%\php.exe" %*'
        'goto :eof'
        ':phpvm_noactive'
        'echo phpvm: no active PHP. Run ''phpvm global ^<ver^>''. 1>&2'
        'exit /b 1'
        ':phpvm_notreg'
        'echo phpvm: PHP %VER% is not registered. Run ''phpvm --list''. 1>&2'
        'exit /b 1'
    ) -join "`r`n"
}

function Initialize-PhpvmDirs {
    $root = Get-PhpvmRoot
    foreach ($sub in @('', 'shim', 'bin', 'versions')) {
        $p = if ($sub) { Join-Path $root $sub } else { $root }
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}

# --- per-version junctions -------------------------------------------------

function Get-PhpvmJunctionTarget {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($item.LinkType -ne 'Junction' -and $item.LinkType -ne 'SymbolicLink') { return $null }
    $t = $item.Target
    if ($t -is [array]) { return [string]($t | Select-Object -First 1) }
    return [string]$t
}

function Remove-PhpvmJunction {
    # Remove the junction link only; never recurse into the target.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        [System.IO.Directory]::Delete($Path, $false)
    } catch {
        & cmd /c rmdir "$Path" 2>$null
    }
}

function New-PhpvmJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        throw "phpvm: junction target is not a directory: $Target"
    }
    if (Test-Path -LiteralPath $Link) {
        $existing = Get-PhpvmJunctionTarget -Path $Link
        if ($existing -and ($existing.TrimEnd('\') -ieq $Target.TrimEnd('\'))) {
            return $Link
        }
        Remove-PhpvmJunction -Path $Link
    }
    $parent = Split-Path -Parent $Link
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType Junction -Path $Link -Value $Target -ErrorAction Stop | Out-Null
    return $Link
}

function Register-PhpvmVersion {
    # Ensure versions\<minor> -> the install dir.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Install)
    $link = Join-Path (Get-PhpvmVersionsDir) $Install.Minor
    New-PhpvmJunction -Link $link -Target $Install.Dir | Out-Null
    return $link
}

function Register-PhpvmVersions {
    # One junction per minor; highest patch wins.
    [CmdletBinding()]
    param([object[]]$Installs)
    if (-not $Installs) { $Installs = Get-AllPhpInstalls }
    $byMinor = @{}
    foreach ($i in $Installs) {
        if (-not $byMinor.ContainsKey($i.Minor)) {
            $byMinor[$i.Minor] = $i
        } elseif ((Compare-PhpVersion $i.Version $byMinor[$i.Minor].Version) -gt 0) {
            $byMinor[$i.Minor] = $i
        }
    }
    $links = @()
    foreach ($m in $byMinor.Keys) {
        try {
            $links += Register-PhpvmVersion -Install $byMinor[$m]
        } catch {
            Write-Warning "phpvm: could not register $m -> $($byMinor[$m].Dir): $($_.Exception.Message)"
        }
    }
    return $links
}

# --- shim + active meta ----------------------------------------------------

function Write-PhpvmResolverShim {
    # Write the static resolver php.cmd. Idempotent; skips the write when current.
    Initialize-PhpvmDirs
    $shimDir = Get-PhpvmShimDir
    $shimCmd = Join-Path $shimDir 'php.cmd'
    $shimExe = Join-Path $shimDir 'php.exe'

    # Stale legacy copy from earlier versions - remove to avoid PATH shadowing.
    if (Test-Path -LiteralPath $shimExe) {
        try { Remove-Item -LiteralPath $shimExe -Force -ErrorAction Stop }
        catch { Write-Warning "phpvm: could not remove stale shim $shimExe - file may be locked" }
    }

    $content = New-PhpvmResolverShimContent
    if (Test-Path -LiteralPath $shimCmd) {
        $existing = Get-Content -LiteralPath $shimCmd -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing.TrimEnd() -eq $content.TrimEnd()) {
            return $shimCmd
        }
    }

    $attempt = 0
    while ($true) {
        try {
            Set-Content -LiteralPath $shimCmd -Value $content -Encoding ASCII -NoNewline
            break
        } catch [System.IO.IOException] {
            $attempt++
            if ($attempt -ge 2) {
                $procs = Get-Process -Name 'php' -ErrorAction SilentlyContinue
                $pids = if ($procs) { ($procs.Id -join ', ') } else { '<none>' }
                throw "phpvm: shim file is locked. Active php.exe PIDs: $pids. Close them and retry."
            }
            Start-Sleep -Milliseconds 250
        }
    }
    return $shimCmd
}

function Write-PhpvmActiveMeta {
    # Persist the global default pointer (the 'global' layer).
    param([Parameter(Mandatory)][object]$Install)
    $file = Join-Path (Get-PhpvmShimDir) '.active'
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lines = @(
        "version=$($Install.Version)"
        "minor=$($Install.Minor)"
        "source=$($Install.Dir)"
        "exe=$($Install.Path)"
        "switched_at=$ts"
    )
    # ASCII (no BOM) so the resolver's findstr reads minor= cleanly.
    Set-Content -LiteralPath $file -Value $lines -Encoding ASCII
}

function Set-PhpvmActive {
    # Set the GLOBAL default: register junctions, write the resolver shim, persist
    # the default pointer. Does not touch any per-terminal env var.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Install,
        [object[]]$Installs,
        [switch]$Quiet
    )
    Initialize-PhpvmDirs
    if (-not $Installs) { $Installs = Get-AllPhpInstalls }
    Register-PhpvmVersions -Installs $Installs | Out-Null
    Write-PhpvmResolverShim | Out-Null
    Write-PhpvmActiveMeta -Install $Install

    if (-not $Quiet) {
        Write-Host "phpvm: global PHP is now $($Install.Version)  ($($Install.Source) - $($Install.Dir))"
    }
}

function Switch-PhpvmTo {
    # Resolve a query and set it as the global default (`phpvm global` / `--set`).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [switch]$Quiet
    )
    $installs = Get-AllPhpInstalls
    if (-not $installs -or $installs.Count -eq 0) {
        throw "phpvm: no PHP installations found. Install via Scoop, XAMPP, Laragon, or extract a build to C:\php82 etc."
    }
    $target = Find-PhpInstallByQuery -Query $Query -Installs $installs
    if (-not $target) {
        $known = ($installs | ForEach-Object { $_.Version }) -join ', '
        throw "phpvm: no installed PHP matches '$Query'. Known: $known"
    }
    Set-PhpvmActive -Install $target -Installs $installs -Quiet:$Quiet
    return $target
}

function Resolve-PhpvmShellTarget {
    # Backing for the hidden `sh-shell` verb the profile wrapper calls. Validates
    # the query, ensures the junction + resolver shim exist, returns the install.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Query)
    $installs = Get-AllPhpInstalls
    $target = Find-PhpInstallByQuery -Query $Query -Installs $installs
    if (-not $target) { return $null }
    Initialize-PhpvmDirs
    Register-PhpvmVersion -Install $target | Out-Null
    Write-PhpvmResolverShim | Out-Null
    return $target
}
