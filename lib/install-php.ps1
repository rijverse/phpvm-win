# lib/install-php.ps1 - fetch PHP from windows.php.net.
# Grab the NTS x64 zip for a minor, check its published SHA256, extract to
# %USERPROFILE%\.phpvm\php\<minor>, and point a versions\<minor> junction at it.
# NTS x64 is what the CLI and the shim want; TS is only for Apache mod_php. If
# Scoop is around we mention it, but never lean on it.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'switch.ps1')

$script:PhpvmReleasesUrl = 'https://windows.php.net/downloads/releases/'
$script:PhpvmArchivesUrl = 'https://windows.php.net/downloads/releases/archives/'

# --- index parsing (no network, so it's easy to test) ---------------------

function Get-PhpZipsFromIndex {
    # pull the NTS x64 zips out of a directory-index page, deduped by name.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Index)
    $rx = [regex]'php-(\d+\.\d+\.\d+)-nts-Win32-v[cs]\d+-x64\.zip'
    $seen = @{}
    $out = @()
    foreach ($m in $rx.Matches($Index)) {
        $file = $m.Value
        if ($seen.ContainsKey($file)) { continue }
        $seen[$file] = $true
        $ver = $m.Groups[1].Value
        $out += [pscustomobject]@{
            FileName = $file
            Version  = $ver
            Minor    = ($ver -replace '^(\d+\.\d+).*', '$1')
        }
    }
    # emit the elements (callers pipe + wrap with @()). do NOT use ,$out here -
    # that nests the whole array into one item and breaks the pipes downstream.
    return $out
}

function Select-PhpZipForMinor {
    # Highest patch of the requested minor.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Index,
        [Parameter(Mandatory)][string]$Minor
    )
    $zips = @(Get-PhpZipsFromIndex -Index $Index | Where-Object { $_.Minor -eq $Minor })
    if ($zips.Count -eq 0) { return $null }
    return ($zips | Sort-Object -Property @{ Expression = { [version]$_.Version }; Descending = $true } | Select-Object -First 1)
}

function Resolve-LatestPhpMinor {
    # Highest X.Y present in an index.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Index)
    $zips = @(Get-PhpZipsFromIndex -Index $Index)
    if ($zips.Count -eq 0) { return $null }
    $minors = $zips | Select-Object -ExpandProperty Minor -Unique
    return ($minors | Sort-Object -Property @{ Expression = { [version]($_ + '.0') }; Descending = $true } | Select-Object -First 1)
}

function Get-Sha256FromSumFile {
    # Pull one file's hash from a sha256sum.txt body ("<hash>  <filename>").
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$FileName
    )
    foreach ($line in ($Content -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            if ($matches[2].Trim() -ieq $FileName) { return $matches[1].ToLowerInvariant() }
        }
    }
    return $null
}

function ConvertTo-PhpInstallPlan {
    # Resolve a minor to a concrete download plan, preferring current releases
    # and falling back to the archives index.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Minor,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReleasesIndex,
        [AllowEmptyString()][string]$ArchivesIndex,
        [string]$ReleasesUrl = $script:PhpvmReleasesUrl,
        [string]$ArchivesUrl = $script:PhpvmArchivesUrl
    )
    $zip = Select-PhpZipForMinor -Index $ReleasesIndex -Minor $Minor
    $base = $ReleasesUrl
    $src = 'releases'
    if (-not $zip -and $ArchivesIndex) {
        $zip = Select-PhpZipForMinor -Index $ArchivesIndex -Minor $Minor
        $base = $ArchivesUrl
        $src = 'archives'
    }
    if (-not $zip) { return $null }
    [pscustomobject]@{
        Minor    = $Minor
        Version  = $zip.Version
        FileName = $zip.FileName
        Url      = ($base.TrimEnd('/') + '/' + $zip.FileName)
        ShaUrl   = ($base.TrimEnd('/') + '/sha256sum.txt')
        Source   = $src
    }
}

# --- network ---------------------------------------------------------------

function Get-PhpUrlContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing
    return [string]$resp.Content
}

function Install-Php {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [switch]$Print,
        [switch]$Force
    )

    # Validate up front, before any network: a minor or 'latest', never a patch.
    $q = ($Query -replace '^php', '').Trim()
    if ($q -match '^\d+\.\d+\.\d+$') {
        throw "phpvm: install takes a minor like 8.2 (got patch '$q'). The latest patch of that minor is installed."
    }
    $isLatest = ($q -ieq 'latest')
    if (-not $isLatest -and $q -notmatch '^\d+\.\d+$') {
        throw "phpvm: invalid version '$Query'. Use a minor like 8.2 or 'latest'."
    }

    if (Get-ScoopRoot) {
        Write-Host "phpvm: Scoop detected. 'scoop install php' is an alternative; continuing with a direct download."
    }

    $relIndex = Get-PhpUrlContent -Url $script:PhpvmReleasesUrl

    if ($isLatest) {
        $minor = Resolve-LatestPhpMinor -Index $relIndex
        if (-not $minor) { throw "phpvm: could not determine the latest PHP from the release index." }
    } else {
        $minor = $q
    }

    $plan = ConvertTo-PhpInstallPlan -Minor $minor -ReleasesIndex $relIndex
    if (-not $plan) {
        $arcIndex = Get-PhpUrlContent -Url $script:PhpvmArchivesUrl
        $plan = ConvertTo-PhpInstallPlan -Minor $minor -ReleasesIndex $relIndex -ArchivesIndex $arcIndex
    }
    if (-not $plan) {
        throw "phpvm: no NTS x64 build for PHP $minor on windows.php.net (checked releases and archives)."
    }

    $phpDir    = Join-Path (Get-PhpvmPhpDir) $minor
    $targetExe = Join-Path $phpDir 'php.exe'

    if ($Print) {
        Write-Host "phpvm: would install PHP $($plan.Version) ($($plan.Source))"
        Write-Host "  url:    $($plan.Url)"
        Write-Host "  sha256: $($plan.ShaUrl)"
        Write-Host "  target: $phpDir"
        return
    }

    if ((Test-Path -LiteralPath $targetExe) -and -not $Force) {
        Write-Host "phpvm: PHP $minor is already installed at $phpDir. Use --force to reinstall."
        New-PhpvmJunction -Link (Join-Path (Get-PhpvmVersionsDir) $minor) -Target $phpDir | Out-Null
        Write-PhpvmResolverShim | Out-Null
        Write-Host "phpvm: run 'phpvm global $minor' (or 'phpvm shell $minor') to use it."
        return
    }

    Initialize-PhpvmDirs
    $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-dl-" + $plan.FileName)
    Write-Host "phpvm: downloading $($plan.Url)"
    Invoke-WebRequest -Uri $plan.Url -OutFile $tmpZip -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $published = $null
    try {
        $published = Get-Sha256FromSumFile -Content (Get-PhpUrlContent -Url $plan.ShaUrl) -FileName $plan.FileName
    } catch { }
    if ($published) {
        if ($actual -ne $published) {
            Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            throw "phpvm: SHA256 mismatch for $($plan.FileName).`n  expected $published`n  got      $actual"
        }
        Write-Host "phpvm: sha256 verified."
    } else {
        Write-Host "phpvm: WARNING - no published sha256 found for $($plan.FileName); downloaded hash is $actual"
    }

    if ((Test-Path -LiteralPath $phpDir) -and $Force) {
        Remove-Item -LiteralPath $phpDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $phpDir -Force | Out-Null
    Write-Host "phpvm: extracting to $phpDir"
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $phpDir -Force
    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $targetExe)) {
        throw "phpvm: extraction did not produce php.exe in $phpDir"
    }

    New-PhpvmJunction -Link (Join-Path (Get-PhpvmVersionsDir) $minor) -Target $phpDir | Out-Null
    Write-PhpvmResolverShim | Out-Null

    Write-Host "phpvm: installed PHP $($plan.Version) -> $phpDir"
    Write-Host "phpvm: run 'phpvm global $minor' (or 'phpvm shell $minor') to use it."
}
