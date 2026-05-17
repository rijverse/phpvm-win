# Pester v5 suite — run via `Invoke-Pester ./tests`

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib/detect.ps1')
    . (Join-Path $repoRoot 'lib/project.ps1')
    . (Join-Path $repoRoot 'lib/switch.ps1')
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'ConvertTo-NormalizedVersionQuery' {
    It 'strips php prefix' {
        ConvertTo-NormalizedVersionQuery -Raw 'php8.2' | Should -Be '8.2'
    }
    It 'accepts X.Y' {
        ConvertTo-NormalizedVersionQuery -Raw '8.2' | Should -Be '8.2'
    }
    It 'accepts X.Y.Z' {
        ConvertTo-NormalizedVersionQuery -Raw '8.2.15' | Should -Be '8.2.15'
    }
    It 'trims whitespace and newlines' {
        ConvertTo-NormalizedVersionQuery -Raw "  8.2`n" | Should -Be '8.2'
    }
    It 'rejects garbage' {
        ConvertTo-NormalizedVersionQuery -Raw 'notaversion' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-PhpMinor' {
    It 'reduces patch to minor' {
        ConvertTo-PhpMinor -Version '8.2.15' | Should -Be '8.2'
    }
    It 'passes through bare minor' {
        ConvertTo-PhpMinor -Version '8.2' | Should -Be '8.2'
    }
}

Describe 'ConvertTo-ComparatorParts' {
    It 'parses caret' {
        $c = ConvertTo-ComparatorParts -Atom '^8.2'
        $c.Op | Should -Be '^'
        $c.Major | Should -Be 8
        $c.Minor | Should -Be 2
    }
    It 'parses tilde with patch' {
        $c = ConvertTo-ComparatorParts -Atom '~8.1.5'
        $c.Op | Should -Be '~'
        $c.HasPatch | Should -BeTrue
        $c.Patch | Should -Be 5
    }
    It 'parses gte' {
        $c = ConvertTo-ComparatorParts -Atom '>=7.4'
        $c.Op | Should -Be '>='
        $c.Major | Should -Be 7
        $c.Minor | Should -Be 4
    }
    It 'parses wildcard minor' {
        $c = ConvertTo-ComparatorParts -Atom '8.*'
        $c.Minor | Should -Be -1
    }
}

Describe 'Test-MinorSatisfiesConstraint' {
    Context 'caret ^8.2' {
        It '8.2 matches'  { Test-MinorSatisfiesConstraint -Minor '8.2' -Constraint '^8.2' | Should -BeTrue }
        It '8.3 matches'  { Test-MinorSatisfiesConstraint -Minor '8.3' -Constraint '^8.2' | Should -BeTrue }
        It '8.1 fails'    { Test-MinorSatisfiesConstraint -Minor '8.1' -Constraint '^8.2' | Should -BeFalse }
        It '9.0 fails'    { Test-MinorSatisfiesConstraint -Minor '9.0' -Constraint '^8.2' | Should -BeFalse }
    }
    Context 'tilde ~8.1.5' {
        It '8.1 matches'  { Test-MinorSatisfiesConstraint -Minor '8.1' -Constraint '~8.1.5' | Should -BeTrue }
        It '8.2 fails'    { Test-MinorSatisfiesConstraint -Minor '8.2' -Constraint '~8.1.5' | Should -BeFalse }
        It '8.0 fails'    { Test-MinorSatisfiesConstraint -Minor '8.0' -Constraint '~8.1.5' | Should -BeFalse }
    }
    Context 'range >=7.4 <8.2' {
        It '7.4 matches'  { Test-MinorSatisfiesConstraint -Minor '7.4' -Constraint '>=7.4 <8.2' | Should -BeTrue }
        It '8.1 matches'  { Test-MinorSatisfiesConstraint -Minor '8.1' -Constraint '>=7.4 <8.2' | Should -BeTrue }
        It '8.2 fails'    { Test-MinorSatisfiesConstraint -Minor '8.2' -Constraint '>=7.4 <8.2' | Should -BeFalse }
        It '7.3 fails'    { Test-MinorSatisfiesConstraint -Minor '7.3' -Constraint '>=7.4 <8.2' | Should -BeFalse }
    }
    Context 'pipe ^7.4 || ^8.0' {
        It '7.4 matches'  { Test-MinorSatisfiesConstraint -Minor '7.4' -Constraint '^7.4 || ^8.0' | Should -BeTrue }
        It '8.3 matches'  { Test-MinorSatisfiesConstraint -Minor '8.3' -Constraint '^7.4 || ^8.0' | Should -BeTrue }
        It '7.3 fails'    { Test-MinorSatisfiesConstraint -Minor '7.3' -Constraint '^7.4 || ^8.0' | Should -BeFalse }
    }
}

Describe 'Get-ComposerPhpConstraint' {
    It 'reads caret' {
        Get-ComposerPhpConstraint -Path (Join-Path $script:Fixtures 'composer-caret.json') | Should -Be '^8.2'
    }
    It 'reads tilde' {
        Get-ComposerPhpConstraint -Path (Join-Path $script:Fixtures 'composer-tilde.json') | Should -Be '~8.1.5'
    }
    It 'reads range' {
        Get-ComposerPhpConstraint -Path (Join-Path $script:Fixtures 'composer-range.json') | Should -Be '>=7.4 <8.2'
    }
    It 'reads pipe' {
        Get-ComposerPhpConstraint -Path (Join-Path $script:Fixtures 'composer-pipe.json') | Should -Be '^7.4 || ^8.0'
    }
}

Describe 'Find-PhpVersionFile walks upward' {
    BeforeAll {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-test-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        $deep = Join-Path $script:tmp 'a/b/c'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tmp '.php-version') -Value '8.2'
        $script:deep = $deep
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:tmp) {
            Remove-Item -LiteralPath $script:tmp -Recurse -Force
        }
    }
    It 'finds parent .php-version from nested dir' {
        $r = Find-PhpVersionFile -StartDir $script:deep
        $r.Query | Should -Be '8.2'
        $r.Kind  | Should -Be 'php-version'
    }
}

Describe 'New-PhpvmShimContent' {
    It 'produces valid cmd shim' {
        $c = New-PhpvmShimContent -TargetExe 'C:\tools\php82\php.exe'
        $c | Should -Match '@echo off'
        $c | Should -Match '"C:\\tools\\php82\\php\.exe" %\*'
    }
    It 'quotes paths with spaces' {
        $c = New-PhpvmShimContent -TargetExe 'C:\Program Files\PHP\php.exe'
        $c | Should -Match '"C:\\Program Files\\PHP\\php\.exe"'
    }
}

Describe 'Find-PhpInstallByQuery' {
    BeforeAll {
        $script:fakeInstalls = @(
            [pscustomobject]@{ Version='8.2.15'; Minor='8.2'; Path='C:\php\82\php.exe'; Dir='C:\php\82'; Source='Manual'; Active=$false }
            [pscustomobject]@{ Version='8.2.10'; Minor='8.2'; Path='D:\php\82a\php.exe'; Dir='D:\php\82a'; Source='Scoop';  Active=$false }
            [pscustomobject]@{ Version='8.1.27'; Minor='8.1'; Path='C:\php\81\php.exe'; Dir='C:\php\81'; Source='Manual'; Active=$false }
        )
    }
    It 'matches by exact full version' {
        (Find-PhpInstallByQuery -Query '8.1.27' -Installs $script:fakeInstalls).Path | Should -Be 'C:\php\81\php.exe'
    }
    It 'matches by minor — highest patch wins' {
        (Find-PhpInstallByQuery -Query '8.2' -Installs $script:fakeInstalls).Version | Should -Be '8.2.15'
    }
    It 'returns null for unknown' {
        Find-PhpInstallByQuery -Query '9.9' -Installs $script:fakeInstalls | Should -BeNullOrEmpty
    }
    It 'strips php prefix' {
        (Find-PhpInstallByQuery -Query 'php8.1' -Installs $script:fakeInstalls).Minor | Should -Be '8.1'
    }
}
