# phpvm auto-switch + per-shell wrapper hook
# Dot-sourced from the PowerShell profile by 'phpvm --enable-hook'. Provides:
#   - a 'phpvm' wrapper so 'phpvm shell <ver>' pins THIS terminal (a child
#     process cannot set the parent's env, so the wrapper must run in-session)
#   - a prompt override that sets PHPVM_AUTO_VERSION (the project layer) on cd
#   - a PATH self-heal that keeps the phpvm shim ahead of other php.exe dirs
# Idempotent: safe to dot-source twice; only the first run wraps the prompt.

if ($global:__PhpvmHookInstalled) { return }
$global:__PhpvmHookInstalled = $true
$global:__PhpvmLastDir = $null

function global:__PhpvmRoot {
    # Mirror lib/detect.ps1 Get-PhpvmRoot so PHPVM_ROOT relocates everything.
    if ($env:PHPVM_ROOT) { return $env:PHPVM_ROOT }
    return (Join-Path $env:USERPROFILE '.phpvm')
}

function global:phpvm {
    $cli = Join-Path (__PhpvmRoot) 'bin\phpvm.ps1'
    if ($args.Count -ge 1 -and $args[0] -eq 'shell') {
        if ($args.Count -ge 2 -and ($args[1] -eq '--unset' -or $args[1] -eq 'unset')) {
            Remove-Item Env:PHPVM_SHELL_VERSION -ErrorAction SilentlyContinue
            Write-Host 'phpvm: shell pin removed for this terminal.'
            return
        }
        if ($args.Count -lt 2) {
            if ($env:PHPVM_SHELL_VERSION) {
                Write-Host "phpvm: this terminal is pinned to PHP $($env:PHPVM_SHELL_VERSION)."
            } else {
                Write-Host 'phpvm: no shell pin in this terminal. Usage: phpvm shell <ver>'
            }
            return
        }
        # sh-shell validates + registers and prints the bare minor on stdout.
        $ver = & $cli 'sh-shell' $args[1]
        if ($LASTEXITCODE -eq 0 -and $ver) {
            $env:PHPVM_SHELL_VERSION = "$ver".Trim()
            Write-Host "phpvm: pinned this terminal to PHP $($env:PHPVM_SHELL_VERSION)."
        }
        return
    }
    & $cli @args
}

function global:__PhpvmPathFix {
    # Keep the phpvm shim dir ahead of any other php.exe dir in the process PATH.
    # No-op when already in front; only probes dirs that precede the shim.
    $shim = (Join-Path (__PhpvmRoot) 'shim').TrimEnd('\')
    $parts = @($env:Path -split ';' | Where-Object { $_ })
    $shimIdx = -1
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i].TrimEnd('\') -ieq $shim) { $shimIdx = $i; break }
    }
    if ($shimIdx -lt 0) {
        $env:Path = $shim + ';' + $env:Path
        return
    }
    for ($i = 0; $i -lt $shimIdx; $i++) {
        if (Test-Path -LiteralPath (Join-Path $parts[$i] 'php.exe') -PathType Leaf) {
            $rest = @($parts | Where-Object { $_.TrimEnd('\') -ine $shim })
            $env:Path = (@($shim) + $rest) -join ';'
            return
        }
    }
}

$global:__PhpvmOriginalPrompt = $function:prompt

function global:prompt {
    __PhpvmPathFix
    if ($PWD.Path -ne $global:__PhpvmLastDir) {
        $global:__PhpvmLastDir = $PWD.Path
        try {
            $cli = Join-Path (__PhpvmRoot) 'bin\phpvm.ps1'
            $v = & $cli --auto --print 2>$null
            $v = "$v".Trim()
            if ($v) { $env:PHPVM_AUTO_VERSION = $v }
            else    { Remove-Item Env:PHPVM_AUTO_VERSION -ErrorAction SilentlyContinue }
        } catch {
            # swallow - the hook must never break the prompt
        }
    }
    if ($global:__PhpvmOriginalPrompt) {
        & $global:__PhpvmOriginalPrompt
    } else {
        "PS $($PWD.Path)> "
    }
}
