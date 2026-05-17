# lib/detect.ps1 — PHP discovery (Scoop + directory scan)
# Returns array of PSCustomObject: Version, Minor, Path, Dir, Source, Active

Set-StrictMode -Version Latest

function Get-PhpvmRoot {
    $home = [Environment]::GetFolderPath('UserProfile')
    Join-Path $home '.phpvm'
}

function Get-PhpvmShimDir {
    Join-Path (Get-PhpvmRoot) 'shim'
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
                $v = Get-PhpExeVersion -Path $phpExe
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
            $v = Get-PhpExeVersion -Path $phpExe
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

    # Sort semver-aware descending
    $sorted = $unique | Sort-Object -Property @{ Expression = { [version]($_.Version + '.0.0.0'.Substring(0, [Math]::Max(0, 7 - $_.Version.Length))) }; Descending = $true }

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

    # Minor match — pick highest patch
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
