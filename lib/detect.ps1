# lib/detect.ps1 - PHP discovery (Scoop + directory scan)
# Returns array of PSCustomObject: Version, Minor, Path, Dir, Source, Active

Set-StrictMode -Version Latest

function Get-PhpvmRoot {
    # PHPVM_ROOT relocates the install (and isolates tests). The resolver shim
    # honors the same override, so the two stay consistent.
    if ($env:PHPVM_ROOT) { return $env:PHPVM_ROOT }
    $userHome = [Environment]::GetFolderPath('UserProfile')
    Join-Path $userHome '.phpvm'
}

function Get-PhpvmShimDir {
    Join-Path (Get-PhpvmRoot) 'shim'
}

function Get-PhpvmVersionsDir {
    # Per-version junctions live here: versions\<minor> -> real install dir.
    Join-Path (Get-PhpvmRoot) 'versions'
}

function Get-PhpvmPhpDir {
    # Downloaded builds (phpvm install) extract here: php\<minor>.
    Join-Path (Get-PhpvmRoot) 'php'
}

function Resolve-PhpvmEffectiveMinor {
    # The three-layer precedence, mirroring the resolver shim: shell > project >
    # global. Each argument is a minor string (e.g. '8.2') or empty.
    param(
        [string]$Shell,
        [string]$Project,
        [string]$Global
    )
    if ($Shell)   { return $Shell }
    if ($Project) { return $Project }
    if ($Global)  { return $Global }
    return $null
}

function Get-PhpvmShimStatus {
    # Shared shim-state probe used by --current, shell, and doctor.
    #   active   - 'php' resolves to our shim
    #   shadowed - 'php' resolves to some other php.exe ahead of the shim
    #   absent   - the shim file is not written yet
    #   noshim   - no 'php' on PATH at all
    $shimDir = Get-PhpvmShimDir
    $shimCmd = Join-Path $shimDir 'php.cmd'
    if (-not (Test-Path -LiteralPath $shimCmd)) { return 'absent' }
    $cmd = Get-Command -Name php -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return 'noshim' }
    $resolved = "$($cmd.Source)"
    if ($resolved -and $resolved.ToLowerInvariant().StartsWith($shimDir.ToLowerInvariant())) {
        return 'active'
    }
    return 'shadowed'
}

function Get-PhpvmActiveMeta {
    $file = Join-Path (Get-PhpvmShimDir) '.active'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $meta = @{}
    foreach ($line in Get-Content -LiteralPath $file -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*([^=#]+?)\s*=\s*(.*?)\s*$') {
            $meta[$matches[1]] = $matches[2]
        }
    }
    return $meta
}

function Test-PhpExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $null = & $Path '-v' 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Get-PhpExeVersion {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $out = & $Path '-r' 'echo PHP_VERSION;' 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) { return $null }
        $v = ($out -join '').Trim()
        if ($v -match '^(\d+\.\d+\.\d+)') { return $matches[1] }
        if ($v -match '^(\d+\.\d+)')       { return "$($matches[1]).0" }
        return $null
    } catch { return $null }
}

function ConvertTo-PhpMinor {
    param([Parameter(Mandatory)][string]$Version)
    if ($Version -match '^(\d+\.\d+)') { return $matches[1] }
    return $Version
}

# --- version cache -----------------------------------------------------------
# Discovery spawns `php.exe -r` per candidate, and the cd-hook discovers on every
# directory change - so probes are cached keyed on the binary's mtime. A replaced
# or upgraded php.exe changes mtime and re-probes; a stale path just misses.

$script:PhpvmVersionCache = @{}
$script:PhpvmVersionCacheLoaded = $false

function Get-PhpvmVersionCacheFile {
    Join-Path (Get-PhpvmRoot) 'cache\php-versions.txt'
}

function Import-PhpvmVersionCache {
    if ($script:PhpvmVersionCacheLoaded) { return }
    $script:PhpvmVersionCacheLoaded = $true
    $file = Get-PhpvmVersionCacheFile
    if (-not (Test-Path -LiteralPath $file)) { return }
    foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        # <mtime-ticks>|<version>|<php.exe path, lowercased>
        $parts = $line -split '\|', 3
        if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$' -and $parts[1] -match '^\d+\.\d+\.\d+$') {
            $script:PhpvmVersionCache[$parts[2]] = @{ Ticks = [long]$parts[0]; Version = $parts[1] }
        }
    }
}

function Save-PhpvmVersionCache {
    # Best effort - a read-only or locked cache must never break discovery.
    try {
        $file = Get-PhpvmVersionCacheFile
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $lines = foreach ($k in $script:PhpvmVersionCache.Keys) {
            $e = $script:PhpvmVersionCache[$k]
            "$($e.Ticks)|$($e.Version)|$k"
        }
        Set-Content -LiteralPath $file -Value $lines -Encoding ASCII
    } catch { }
}

function Get-PhpExeVersionCached {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    Import-PhpvmVersionCache
    $key = $Path.ToLowerInvariant()
    $ticks = $item.LastWriteTimeUtc.Ticks
    if ($script:PhpvmVersionCache.ContainsKey($key) -and $script:PhpvmVersionCache[$key].Ticks -eq $ticks) {
        return $script:PhpvmVersionCache[$key].Version
    }
    $v = Get-PhpExeVersion -Path $Path
    if ($v) {
        $script:PhpvmVersionCache[$key] = @{ Ticks = $ticks; Version = $v }
        Save-PhpvmVersionCache
    }
    return $v
}

function Get-ScoopRoot {
    if ($env:SCOOP -and (Test-Path -LiteralPath $env:SCOOP)) { return $env:SCOOP }
    $candidate = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'scoop'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-ScoopPhpInstalls {
    $scoopRoot = Get-ScoopRoot
    if (-not $scoopRoot) { return @() }
    $appsRoot = Join-Path $scoopRoot 'apps'
    if (-not (Test-Path -LiteralPath $appsRoot)) { return @() }
    $results = @()
    Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^php(\d{2,3})?$' } |
        ForEach-Object {
            $currentDir = Join-Path $_.FullName 'current'
            $phpExe = Join-Path $currentDir 'php.exe'
            if (Test-Path -LiteralPath $phpExe) {
                $v = Get-PhpExeVersionCached -Path $phpExe
                if ($v) {
                    $results += [pscustomobject]@{
                        Version = $v
                        Minor   = ConvertTo-PhpMinor $v
                        Path    = $phpExe
                        Dir     = $currentDir
                        Source  = 'Scoop'
                        Active  = $false
                    }
                }
            }
        }
    return $results
}

function Get-DefaultSearchGlobs {
    if ($env:PHPVM_SEARCH_PATHS) {
        return $env:PHPVM_SEARCH_PATHS -split ';' | Where-Object { $_ }
    }
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    @(
        'C:\php*'
        'C:\tools\php*'
        'C:\xampp\php'
        'C:\laragon\bin\php\php-*'
        'C:\wamp64\bin\php\php*'
        (Join-Path $localAppData 'Programs\php*')
    )
}

function Resolve-PhpSource {
    param([Parameter(Mandatory)][string]$Dir)
    $d = $Dir.ToLowerInvariant()
    if ($d -match 'xampp')   { return 'XAMPP' }
    if ($d -match 'laragon') { return 'Laragon' }
    if ($d -match 'wamp')    { return 'WAMP' }
    if ($d -match '\\scoop\\') { return 'Scoop' }
    return 'Manual'
}

function Get-FilesystemPhpInstalls {
    $results = @()
    foreach ($glob in Get-DefaultSearchGlobs) {
        $matches2 = Get-Item -Path $glob -ErrorAction SilentlyContinue
        foreach ($m in $matches2) {
            if (-not $m.PSIsContainer) { continue }
            $phpExe = Join-Path $m.FullName 'php.exe'
            if (-not (Test-Path -LiteralPath $phpExe)) { continue }
            $v = Get-PhpExeVersionCached -Path $phpExe
            if (-not $v) { continue }
            $results += [pscustomobject]@{
                Version = $v
                Minor   = ConvertTo-PhpMinor $v
                Path    = $phpExe
                Dir     = $m.FullName
                Source  = Resolve-PhpSource $m.FullName
                Active  = $false
            }
        }
    }
    return $results
}

function Get-PhpvmManagedInstalls {
    # Builds installed by `phpvm install` live under %USERPROFILE%\.phpvm\php\<minor>.
    # These are always discovered, independent of PHPVM_SEARCH_PATHS.
    $phpRoot = Get-PhpvmPhpDir
    if (-not (Test-Path -LiteralPath $phpRoot)) { return @() }
    $results = @()
    Get-ChildItem -LiteralPath $phpRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $phpExe = Join-Path $_.FullName 'php.exe'
        if (Test-Path -LiteralPath $phpExe) {
            $v = Get-PhpExeVersionCached -Path $phpExe
            if ($v) {
                $results += [pscustomobject]@{
                    Version = $v
                    Minor   = ConvertTo-PhpMinor $v
                    Path    = $phpExe
                    Dir     = $_.FullName
                    Source  = 'phpvm'
                    Active  = $false
                }
            }
        }
    }
    return $results
}

function Compare-PhpVersion {
    param([string]$A, [string]$B)
    $pa = ($A -split '\.') + @('0', '0', '0') | Select-Object -First 3
    $pb = ($B -split '\.') + @('0', '0', '0') | Select-Object -First 3
    for ($i = 0; $i -lt 3; $i++) {
        $na = [int]($pa[$i] -replace '\D.*$', '')
        $nb = [int]($pb[$i] -replace '\D.*$', '')
        if ($na -ne $nb) { return $na - $nb }
    }
    return 0
}

function Get-AllPhpInstalls {
    [CmdletBinding()]
    param()

    $all = @()
    $all += Get-PhpvmManagedInstalls
    $all += Get-ScoopPhpInstalls
    $all += Get-FilesystemPhpInstalls

    # Dedupe by canonical path
    $seen = @{}
    $unique = @()
    foreach ($i in $all) {
        $key = $i.Path.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $i
        }
    }

    # Sort semver-aware descending. Wrap in @() so a single install stays an
    # array through the `return ,$sorted` below (a bare scalar would collapse).
    $sorted = @($unique | Sort-Object -Property @{
        Expression = {
            $parts = $_.Version -split '\.'
            while ($parts.Count -lt 4) { $parts += '0' }
            [version](($parts | Select-Object -First 4) -join '.')
        }
        Descending = $true
    })

    # Mark active
    $active = Get-ActivePhpInstall -Installs $sorted
    if ($active) {
        foreach ($i in $sorted) {
            if ($i.Path -eq $active.Path) { $i.Active = $true }
        }
    }
    return ,$sorted
}

function Get-ActivePhpInstall {
    [CmdletBinding()]
    param([object[]]$Installs)

    if (-not $Installs) { $Installs = Get-AllPhpInstalls }

    # Prefer shim metadata
    $meta = Get-PhpvmActiveMeta
    if ($meta -and $meta.ContainsKey('source')) {
        $srcDir = $meta['source']
        $hit = $Installs | Where-Object { $_.Dir -ieq $srcDir } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    # Fall back to first php in PATH
    $cmd = Get-Command -Name php -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $resolved = $cmd.Source

    # If shim, resolve its target
    $shimDir = Get-PhpvmShimDir
    if ($resolved -and $resolved.ToLowerInvariant().StartsWith($shimDir.ToLowerInvariant())) {
        if ($meta -and $meta.ContainsKey('source')) {
            $srcDir = $meta['source']
            $hit = $Installs | Where-Object { $_.Dir -ieq $srcDir } | Select-Object -First 1
            if ($hit) { return $hit }
        }
        return $null
    }

    $hit = $Installs | Where-Object { $_.Path -ieq $resolved } | Select-Object -First 1
    return $hit
}

function Find-PhpInstallByQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [object[]]$Installs
    )
    if (-not $Installs) { $Installs = Get-AllPhpInstalls }

    $q = ($Query -replace '^php', '').Trim()

    # Exact full version
    $hit = $Installs | Where-Object { $_.Version -eq $q } | Select-Object -First 1
    if ($hit) { return $hit }

    # Minor match - pick highest patch
    if ($q -match '^\d+\.\d+$') {
        $hits = $Installs | Where-Object { $_.Minor -eq $q }
        if ($hits) {
            $sorted = $hits | Sort-Object -Property @{
                Expression = { [version]$_.Version }; Descending = $true
            }
            return $sorted | Select-Object -First 1
        }
    }

    # Prefix match
    $hits = $Installs | Where-Object { $_.Version.StartsWith($q) }
    if ($hits) { return $hits | Select-Object -First 1 }

    return $null
}

function Resolve-PhpvmWhich {
    # Resolve a version query to a php.exe path. Returns the bare path or $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [object[]]$Installs
    )
    if (-not $Installs) { $Installs = Get-AllPhpInstalls }
    $hit = Find-PhpInstallByQuery -Query $Query -Installs $Installs
    if ($hit) { return $hit.Path }
    return $null
}

function ConvertTo-PhpInstallsJson {
    # Serialize installs to a JSON array of {version, path, active}. Always an array.
    [CmdletBinding()]
    param([object[]]$Installs)
    if (-not $Installs -or $Installs.Count -eq 0) { return '[]' }
    $rows = foreach ($i in $Installs) {
        [ordered]@{
            version = $i.Version
            path    = $i.Path
            active  = [bool]$i.Active
        }
    }
    return (ConvertTo-Json -InputObject @($rows) -Depth 4)
}
