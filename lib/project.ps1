# lib/project.ps1 - project detection
# .php-version + composer.json require.php parser

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'detect.ps1')

function ConvertTo-NormalizedVersionQuery {
    param([Parameter(Mandatory)][string]$Raw)
    $s = ($Raw -replace '^php', '').Trim()
    if ($s -match '^(\d+\.\d+(?:\.\d+)?)$') { return $matches[1] }
    return $null
}

function Find-PhpVersionFile {
    param([string]$StartDir = (Get-Location).Path)
    $dir = (Resolve-Path -LiteralPath $StartDir).Path
    while ($true) {
        $candidate = Join-Path $dir '.php-version'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $raw = (Get-Content -LiteralPath $candidate -Raw -ErrorAction SilentlyContinue)
            if ($null -ne $raw) {
                $norm = ConvertTo-NormalizedVersionQuery -Raw ($raw.Trim())
                if ($norm) {
                    return [pscustomobject]@{ Source = $candidate; Query = $norm; Kind = 'php-version' }
                }
            }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
}

function Find-ComposerJson {
    param([string]$StartDir = (Get-Location).Path)
    $dir = (Resolve-Path -LiteralPath $StartDir).Path
    while ($true) {
        $candidate = Join-Path $dir 'composer.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
}

function Get-ComposerPhpConstraint {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch { return $null }
    if (-not $json) { return $null }
    if ($json.PSObject.Properties['require'] -and $json.require.PSObject.Properties['php']) {
        return [string]$json.require.php
    }
    return $null
}

# Parse one atomic comparator: '>=8.1', '^8.2', '~8.1.5', '8.*', '8.2.5'
# Returns hashtable { Op; Major; Minor; Patch; HasMinor; HasPatch }
function ConvertTo-ComparatorParts {
    param([Parameter(Mandatory)][string]$Atom)
    $a = $Atom.Trim()
    if (-not $a) { return $null }

    $op = '='
    if ($a.StartsWith('^'))      { $op = '^'; $a = $a.Substring(1) }
    elseif ($a.StartsWith('~'))  { $op = '~'; $a = $a.Substring(1) }
    elseif ($a.StartsWith('>=')) { $op = '>='; $a = $a.Substring(2) }
    elseif ($a.StartsWith('<=')) { $op = '<='; $a = $a.Substring(2) }
    elseif ($a.StartsWith('>'))  { $op = '>'; $a = $a.Substring(1) }
    elseif ($a.StartsWith('<'))  { $op = '<'; $a = $a.Substring(1) }
    elseif ($a.StartsWith('='))  { $op = '='; $a = $a.Substring(1) }

    $a = $a.Trim()
    $a = $a -replace '[\-+].*$', ''   # strip pre-release / build metadata
    $a = $a -replace 'v', ''

    if ($a -match '^\*$|^\*\.\*$') {
        return @{ Op = '*'; Major = 0; Minor = 0; Patch = 0; HasMinor = $false; HasPatch = $false }
    }

    if ($a -notmatch '^(\d+)(?:\.(\d+|\*))?(?:\.(\d+|\*))?$') { return $null }

    $major = [int]$matches[1]
    $hasMinor = $matches[2] -ne $null -and $matches[2] -ne ''
    $hasPatch = $matches[3] -ne $null -and $matches[3] -ne ''

    $minor = 0
    if ($hasMinor) {
        if ($matches[2] -eq '*') { $minor = -1 } else { $minor = [int]$matches[2] }
    }
    $patch = 0
    if ($hasPatch) {
        if ($matches[3] -eq '*') { $patch = -1 } else { $patch = [int]$matches[3] }
    }

    return @{
        Op = $op; Major = $major; Minor = $minor; Patch = $patch
        HasMinor = $hasMinor; HasPatch = $hasPatch
    }
}

# Test if 'minor' (X.Y) satisfies a single comparator.
function Test-MinorSatisfiesComparator {
    param(
        [Parameter(Mandatory)][string]$Minor,
        [Parameter(Mandatory)][hashtable]$Cmp
    )
    if ($Minor -notmatch '^(\d+)\.(\d+)$') { return $false }
    $iMajor = [int]$matches[1]
    $iMinor = [int]$matches[2]

    switch ($Cmp.Op) {
        '*' { return $true }

        '=' {
            if (-not $Cmp.HasMinor) { return $iMajor -eq $Cmp.Major }
            if ($Cmp.Minor -eq -1)  { return $iMajor -eq $Cmp.Major }
            return ($iMajor -eq $Cmp.Major -and $iMinor -eq $Cmp.Minor)
        }

        '^' {
            # ^X.Y[.Z] - >= X.Y.Z, < (X+1).0.0   (for X >= 1)
            # ^0.Y.Z  - >= 0.Y.Z, < 0.(Y+1).0    (composer follows semver)
            if ($Cmp.Major -ge 1) {
                if ($iMajor -ne $Cmp.Major) { return $false }
                if ($Cmp.HasMinor -and $Cmp.Minor -ne -1) {
                    return $iMinor -ge $Cmp.Minor
                }
                return $true
            } else {
                if (-not $Cmp.HasMinor) { return $iMajor -eq 0 }
                return ($iMajor -eq 0 -and $iMinor -eq $Cmp.Minor)
            }
        }

        '~' {
            # ~X.Y    - >= X.Y.0, < (X+1).0.0
            # ~X.Y.Z  - >= X.Y.Z, < X.(Y+1).0
            if (-not $Cmp.HasMinor) { return $iMajor -eq $Cmp.Major }
            if ($Cmp.HasPatch) {
                return ($iMajor -eq $Cmp.Major -and $iMinor -eq $Cmp.Minor)
            }
            return ($iMajor -eq $Cmp.Major -and $iMinor -ge $Cmp.Minor)
        }

        '>=' {
            if ($iMajor -ne $Cmp.Major) { return $iMajor -gt $Cmp.Major }
            if (-not $Cmp.HasMinor) { return $true }
            return $iMinor -ge $Cmp.Minor
        }

        '>' {
            if ($iMajor -ne $Cmp.Major) { return $iMajor -gt $Cmp.Major }
            if (-not $Cmp.HasMinor) { return $false }
            return $iMinor -gt $Cmp.Minor
        }

        '<=' {
            if ($iMajor -ne $Cmp.Major) { return $iMajor -lt $Cmp.Major }
            if (-not $Cmp.HasMinor) { return $true }
            return $iMinor -le $Cmp.Minor
        }

        '<' {
            if ($iMajor -ne $Cmp.Major) { return $iMajor -lt $Cmp.Major }
            if (-not $Cmp.HasMinor) { return $false }
            return $iMinor -lt $Cmp.Minor
        }
    }
    return $false
}

function Test-MinorSatisfiesConstraint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Minor,
        [Parameter(Mandatory)][string]$Constraint
    )
    # Pipe alternatives: any branch matches -> match.
    foreach ($branch in ($Constraint -split '\|\|?')) {
        $branch = $branch.Trim()
        if (-not $branch) { continue }
        # Spaces inside a branch = AND. Also handle ', ' as AND (some projects).
        $atoms = $branch -split '[\s,]+' | Where-Object { $_ }
        $allMatch = $true
        foreach ($atom in $atoms) {
            $cmp = ConvertTo-ComparatorParts -Atom $atom
            if (-not $cmp) { $allMatch = $false; break }
            if (-not (Test-MinorSatisfiesComparator -Minor $Minor -Cmp $cmp)) {
                $allMatch = $false; break
            }
        }
        if ($allMatch) { return $true }
    }
    return $false
}

function Resolve-ProjectPhpQuery {
    [CmdletBinding()]
    param(
        [string]$StartDir = (Get-Location).Path,
        [object[]]$Installs
    )

    # 1. .php-version wins
    $vf = Find-PhpVersionFile -StartDir $StartDir
    if ($vf) { return $vf }

    # 2. composer.json require.php
    $cj = Find-ComposerJson -StartDir $StartDir
    if (-not $cj) { return $null }
    $constraint = Get-ComposerPhpConstraint -Path $cj
    if (-not $constraint) { return $null }

    if (-not $Installs) { $Installs = Get-AllPhpInstalls }
    $candidateMinors = ($Installs | ForEach-Object { $_.Minor } | Sort-Object -Unique | Sort-Object -Property @{
        Expression = { [version]($_ + '.0') }; Descending = $true
    })

    foreach ($m in $candidateMinors) {
        if (Test-MinorSatisfiesConstraint -Minor $m -Constraint $constraint) {
            return [pscustomobject]@{ Source = $cj; Query = $m; Kind = 'composer' }
        }
    }

    # Fallback - first X.Y in raw constraint string
    if ($constraint -match '(\d+\.\d+)') {
        return [pscustomobject]@{ Source = $cj; Query = $matches[1]; Kind = 'composer-fallback' }
    }
    return $null
}

function Write-PhpVersionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$Dir = (Get-Location).Path
    )
    $norm = ConvertTo-NormalizedVersionQuery -Raw $Version
    if (-not $norm) { throw "phpvm: invalid version '$Version' for .php-version" }
    $file = Join-Path $Dir '.php-version'
    Set-Content -LiteralPath $file -Value $norm -Encoding ASCII
    return $file
}
