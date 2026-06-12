# lib/doctor.ps1 - diagnostics. Exit code = fail count.

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

    # 3. php.cmd resolver shim present + well-formed?
    $shimCmd = Join-Path $shimDir 'php.cmd'
    if (Test-Path -LiteralPath $shimCmd) {
        $content = Get-Content -LiteralPath $shimCmd -Raw -ErrorAction SilentlyContinue
        if ($content -match 'PHPVM_SHELL_VERSION' -and $content -match 'versions\\%VER%') {
            _PhpvmReport pass "resolver shim present: $shimCmd"
        } else {
            _PhpvmReport warn "shim is an old single-target form" "phpvm global <ver> to rewrite the resolver shim"
            $warn++
        }
    } else {
        _PhpvmReport warn "no shim yet (php.cmd missing)" "phpvm global <ver>"
        $warn++
    }

    # 4. `php --version` works
    $cmd = Get-Command -Name php -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        try {
            $v = & $cmd.Source '-v' 2>$null | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and $v) {
                _PhpvmReport pass "php --version -> $v"
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

    # 4b. Per-shell switching
    Write-Host ''
    Write-Host "Per-shell switching:"
    $shimStatus = Get-PhpvmShimStatus
    switch ($shimStatus) {
        'active'   { _PhpvmReport pass "php resolves to the phpvm shim" }
        'shadowed' { _PhpvmReport fail "php resolves to a non-shim php.exe ahead of the shim" "another tool prepended php to PATH; open a new shell or fix PATH order"; $fail++ }
        'absent'   { _PhpvmReport warn "no shim yet" "phpvm global <ver>"; $warn++ }
        'noshim'   { _PhpvmReport warn "no php on PATH" "open a new shell, or phpvm global <ver>"; $warn++ }
    }

    $versionsDir = Get-PhpvmVersionsDir
    if (Test-Path -LiteralPath $versionsDir) {
        $junctions = @(Get-ChildItem -LiteralPath $versionsDir -Directory -ErrorAction SilentlyContinue)
        if ($junctions.Count -gt 0) {
            $names = ($junctions | ForEach-Object { $_.Name } | Sort-Object) -join ', '
            _PhpvmReport pass "registered versions: $names"
        } else {
            _PhpvmReport info "no per-version junctions yet" "phpvm global <ver> or phpvm shell <ver> registers them"
        }
    } else {
        _PhpvmReport info "versions dir not created yet: $versionsDir"
    }

    $meta = Get-PhpvmActiveMeta
    $globalLayer  = if ($meta -and $meta.ContainsKey('minor')) { $meta['minor'] } else { '(none)' }
    $shellLayer   = if ($env:PHPVM_SHELL_VERSION) { $env:PHPVM_SHELL_VERSION } else { '(unset)' }
    $projectLayer = if ($env:PHPVM_AUTO_VERSION)  { $env:PHPVM_AUTO_VERSION }  else { '(none)' }
    _PhpvmReport info "layers - shell: $shellLayer  project: $projectLayer  global: $globalLayer"

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

    # 8b. A .php-version that exists but does not parse is silently skipped by
    # the resolver - surface it here, where a human is looking.
    $dir = (Get-Location).Path
    while ($dir) {
        $vf = Join-Path $dir '.php-version'
        if (Test-Path -LiteralPath $vf -PathType Leaf) {
            $raw = Get-Content -LiteralPath $vf -Raw -ErrorAction SilentlyContinue
            $trimmed = if ($null -ne $raw) { $raw.Trim() } else { '' }
            if (-not $trimmed -or -not (ConvertTo-NormalizedVersionQuery -Raw $trimmed)) {
                _PhpvmReport warn "unparseable .php-version: $vf (content: '$trimmed')" "use a bare version like 8.2"
                $warn++
            }
            break
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    # 9. PHPRC warning
    if ($env:PHPRC) {
        _PhpvmReport warn "PHPRC is set to $env:PHPRC - may override extension dir for any active PHP"
        $warn++
    }

    Write-Host ''
    Write-Host "phpvm doctor: $fail failure(s), $warn warning(s)"
    return $fail
}
