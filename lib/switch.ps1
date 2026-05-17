# lib/switch.ps1 — shim writer + active state mgmt
# Strategy: write a .cmd wrapper in %USERPROFILE%\.phpvm\shim\php.cmd that
# forwards to the real php.exe. No DLL drift, no PATH churn, no admin needed.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'detect.ps1')

function New-PhpvmShimContent {
    param([Parameter(Mandatory)][string]$TargetExe)
    # Use 8.3 short path? No — full path is fine, %~dp0 only for shim's own dir.
    # cmd.exe sees backslashes natively; quote target to survive spaces.
    @(
        '@echo off'
        "`"$TargetExe`" %*"
    ) -join "`r`n"
}

function Initialize-PhpvmDirs {
    $root = Get-PhpvmRoot
    foreach ($sub in @('', 'shim', 'bin')) {
        $p = if ($sub) { Join-Path $root $sub } else { $root }
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}

function Write-PhpvmActiveMeta {
    param(
        [Parameter(Mandatory)][object]$Install
    )
    $file = Join-Path (Get-PhpvmShimDir) '.active'
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lines = @(
        "version=$($Install.Version)"
        "minor=$($Install.Minor)"
        "source=$($Install.Dir)"
        "exe=$($Install.Path)"
        "switched_at=$ts"
    )
    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
}

function Set-PhpvmActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Install,
        [switch]$Quiet
    )

    Initialize-PhpvmDirs

    $shimDir = Get-PhpvmShimDir
    $shimCmd = Join-Path $shimDir 'php.cmd'
    $shimExe = Join-Path $shimDir 'php.exe'

    # Stale legacy copy from earlier versions — remove to avoid PATH shadowing.
    if (Test-Path -LiteralPath $shimExe) {
        try { Remove-Item -LiteralPath $shimExe -Force -ErrorAction Stop }
        catch {
            Write-Warning "phpvm: could not remove stale shim $shimExe — file may be locked"
        }
    }

    $content = New-PhpvmShimContent -TargetExe $Install.Path

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

    Write-PhpvmActiveMeta -Install $Install

    if (-not $Quiet) {
        Write-Host "phpvm: switched to PHP $($Install.Version)  ($($Install.Source) — $($Install.Dir))"
    }
}

function Switch-PhpvmTo {
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
    Set-PhpvmActive -Install $target -Quiet:$Quiet
    return $target
}
