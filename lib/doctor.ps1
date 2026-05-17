# lib/doctor.ps1 — diagnostics. Exit code = fail count.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'detect.ps1')
. (Join-Path $PSScriptRoot 'project.ps1')

function _PhpvmReport {
    param(
        [ValidateSet('pass', 'warn', 'fail', 'info')][string]$Status,
        [string]$Message,
        [string]$Hint
    )
    $glyph = switch ($Status) {
        'pass' { 'OK ' }
        'warn' { '!! ' }
        'fail' { 'XX ' }
        'info' { '.. ' }
    }
    Write-Host "$glyph $Message"
    if ($Hint) { Write-Host "      hint: $Hint" }
}

function Invoke-PhpvmDoctor {
    [CmdletBinding()]
    param()

    $fail = 0
    $warn = 0

    $root    = Get-PhpvmRoot
    $shimDir = Get-PhpvmShimDir
    $binDir  = Join-Path $root 'bin'
    $hookFile = Join-Path $root 'profile-hook.ps1'

    # 1. Install dirs
    if (Test-Path -LiteralPath $root) {
        _PhpvmReport pass "install root present: $root"
    } else {
        _PhpvmReport fail "install root missing: $root" "re-run install.ps1"
        $fail++
    }

    # 2. Shim dir + PATH membership
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathDirs = if ($userPath) { $userPath -split ';' } else { @() }
    $shimInPath = $pathDirs | Where-Object { $_ -ieq $shimDir } | Select-Object -First 1
    $binInPath  = $pathDirs | Where-Object { $_ -ieq $binDir  } | Select-Object -First 1

    if (Test-Path -LiteralPath $shimDir) {
        _PhpvmReport pass "shim dir exists: $shimDir"
    } else {
        _PhpvmReport fail "shim dir missing: $shimDir" "re-run install.ps1"
        $fail++
    }
    if ($shimInPath) {
        _PhpvmReport pass "shim dir is in user PATH"
    } else {
        _PhpvmReport fail "shim dir NOT in user PATH" "re-run install.ps1, or add manually via setx"
        $fail++
    }
    if ($binInPath) {
        _PhpvmReport pass "bin dir is in user PATH"
    } else {
        _PhpvmReport warn "bin dir NOT in user PATH" "phpvm command may not resolve in new shells"
        $warn++
    }

    # 3. php.cmd shim valid?
    $shimCmd = Join-Path $shimDir 'php.cmd'
    if (Test-Path -LiteralPath $shimCmd) {
        $content = Get-Content -LiteralPath $shimCmd -Raw -ErrorAction SilentlyContinue
        if ($content -match '"([^"]+php\.exe)"') {
            $target = $matches[1]
            if (Test-Path -LiteralPath $target) {
                _PhpvmReport pass "shim → $target"
            } else {
                _PhpvmReport fail "shim points at missing exe: $target" "phpvm --set <ver> to repair"
                $fail++
            }
        } else {
            _PhpvmReport fail "shim content unparseable" "phpvm --set <ver> to rewrite"
            $fail++
        }
    } else {
        _PhpvmReport warn "no active version set (php.cmd shim missing)" "phpvm --set <ver>"
        $warn++
    }

    # 4. `php --version` works
    $cmd = Get-Command -Name php -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        try {
            $v = & $cmd.Source '-v' 2>$null | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and $v) {
                _PhpvmReport pass "php --version → $v"
            } else {
                _PhpvmReport fail "php executable exists but '-v' failed" "check antivirus quarantine"
                $fail++
            }
        } catch {
            _PhpvmReport fail "php --version threw: $($_.Exception.Message)"
            $fail++
        }
    } else {
        _PhpvmReport fail "php not on PATH" "open a new shell, or check user PATH"
        $fail++
    }

    # 5. Hook installed
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (Test-Path -LiteralPath $profilePath) {
        $profileContent = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
        if ($profileContent -and $profileContent -match '# phpvm auto-switch') {
            _PhpvmReport pass "auto-switch hook present in profile"
        } else {
            _PhpvmReport info "auto-switch hook not installed" "phpvm --enable-hook"
        }
    } else {
        _PhpvmReport info "no PowerShell profile yet" "phpvm --enable-hook will create one"
    }

    # 6. Execution policy
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -in @('Restricted', 'AllSigned')) {
        _PhpvmReport fail "execution policy is $policy" "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
        $fail++
    } else {
        _PhpvmReport pass "execution policy: $policy"
    }

    # 7. Scoop info
    $scoop = Get-ScoopRoot
    if ($scoop) { _PhpvmReport info "Scoop root: $scoop" }
    else        { _PhpvmReport info "Scoop not detected" }

    # 8. Project detection in cwd
    $proj = Resolve-ProjectPhpQuery -StartDir (Get-Location).Path
    if ($proj) {
        _PhpvmReport info "project query: $($proj.Query) (from $($proj.Source))"
    } else {
        _PhpvmReport info "no project PHP requirement in cwd or ancestors"
    }

    # 9. PHPRC warning
    if ($env:PHPRC) {
        _PhpvmReport warn "PHPRC is set to $env:PHPRC — may override extension dir for any active PHP"
        $warn++
    }

    Write-Host ''
    Write-Host "phpvm doctor: $fail failure(s), $warn warning(s)"
    return $fail
}
