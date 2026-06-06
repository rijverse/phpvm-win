# Pester v5 suite - run via `Invoke-Pester ./tests`

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib/detect.ps1')
    . (Join-Path $repoRoot 'lib/project.ps1')
    . (Join-Path $repoRoot 'lib/switch.ps1')
    . (Join-Path $repoRoot 'lib/install-php.ps1')
    . (Join-Path $repoRoot 'lib/gui.ps1')
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

Describe 'New-PhpvmResolverShimContent' {
    BeforeAll { $script:shim = New-PhpvmResolverShimContent }
    It 'starts with @echo off' {
        $script:shim | Should -Match '@echo off'
    }
    It 'reads the shell layer first' {
        $script:shim | Should -Match 'PHPVM_SHELL_VERSION'
    }
    It 'falls back to the project layer' {
        $script:shim | Should -Match 'PHPVM_AUTO_VERSION'
    }
    It 'falls back to the global default in .active' {
        $script:shim | Should -Match 'findstr /b "minor="'
    }
    It 'dispatches to a per-version junction, not a hard-coded exe' {
        $script:shim | Should -Match 'versions\\%VER%\\php\.exe'
        $script:shim | Should -Not -Match 'C:\\\\'
    }
    It 'errors when no layer resolves' {
        $script:shim | Should -Match 'no active PHP'
        $script:shim | Should -Match 'exit /b 1'
    }
}

Describe 'Per-version junctions' {
    BeforeAll {
        $script:jbase = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-jt-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        $script:t1 = Join-Path $script:jbase 't1'
        $script:t2 = Join-Path $script:jbase 't2'
        $script:link = Join-Path $script:jbase 'link'
        New-Item -ItemType Directory -Path $script:t1 -Force | Out-Null
        New-Item -ItemType Directory -Path $script:t2 -Force | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:jbase) {
            Remove-Item -LiteralPath $script:jbase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'creates a junction to the target' {
        New-PhpvmJunction -Link $script:link -Target $script:t1 | Out-Null
        (Get-PhpvmJunctionTarget -Path $script:link).TrimEnd('\') | Should -Be $script:t1.TrimEnd('\')
    }
    It 'is idempotent when the target is unchanged' {
        { New-PhpvmJunction -Link $script:link -Target $script:t1 } | Should -Not -Throw
        (Get-PhpvmJunctionTarget -Path $script:link).TrimEnd('\') | Should -Be $script:t1.TrimEnd('\')
    }
    It 'repoints when the target changes' {
        New-PhpvmJunction -Link $script:link -Target $script:t2 | Out-Null
        (Get-PhpvmJunctionTarget -Path $script:link).TrimEnd('\') | Should -Be $script:t2.TrimEnd('\')
    }
    It 'removing the junction leaves the target intact' {
        Set-Content -LiteralPath (Join-Path $script:t2 'keep.txt') -Value 'x' -Encoding ASCII
        Remove-PhpvmJunction -Path $script:link
        Test-Path -LiteralPath $script:link | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:t2 'keep.txt') | Should -BeTrue
    }
    It 'rejects a missing target' {
        { New-PhpvmJunction -Link $script:link -Target (Join-Path $script:jbase 'nope') } | Should -Throw
    }
}

Describe 'Resolve-PhpvmEffectiveMinor (layer precedence)' {
    It 'shell beats project and global' {
        Resolve-PhpvmEffectiveMinor -Shell '8.4' -Project '8.2' -Global '8.1' | Should -Be '8.4'
    }
    It 'project beats global when no shell pin' {
        Resolve-PhpvmEffectiveMinor -Shell '' -Project '8.2' -Global '8.1' | Should -Be '8.2'
    }
    It 'falls back to global' {
        Resolve-PhpvmEffectiveMinor -Shell '' -Project '' -Global '8.1' | Should -Be '8.1'
    }
    It 'returns null when no layer is set' {
        Resolve-PhpvmEffectiveMinor -Shell '' -Project '' -Global '' | Should -BeNullOrEmpty
    }
}

Describe 'PHP install resolvers' {
    BeforeAll {
        # Mirrors a real windows.php.net release index (links appear twice, like
        # autoindex href + text; includes vc15/vs16/vs17 and a TS zip to ignore).
        $script:idx = @'
<a href="php-7.4.33-nts-Win32-vc15-x64.zip">php-7.4.33-nts-Win32-vc15-x64.zip</a>
<a href="php-8.1.34-nts-Win32-vs16-x64.zip">php-8.1.34-nts-Win32-vs16-x64.zip</a>
<a href="php-8.2.30-nts-Win32-vs16-x64.zip">php-8.2.30-nts-Win32-vs16-x64.zip</a>
<a href="php-8.2.31-nts-Win32-vs16-x64.zip">php-8.2.31-nts-Win32-vs16-x64.zip</a>
<a href="php-8.3.31-nts-Win32-vs16-x64.zip">php-8.3.31-nts-Win32-vs16-x64.zip</a>
<a href="php-8.4.22-nts-Win32-vs17-x64.zip">php-8.4.22-nts-Win32-vs17-x64.zip</a>
<a href="php-8.2.31-Win32-vs16-x64.zip">php-8.2.31-Win32-vs16-x64.zip</a>
'@
    }

    Context 'Select-PhpZipForMinor' {
        It 'picks the highest patch for a minor' {
            (Select-PhpZipForMinor -Index $script:idx -Minor '8.2').Version | Should -Be '8.2.31'
        }
        It 'handles the vc15 tag (7.4)' {
            (Select-PhpZipForMinor -Index $script:idx -Minor '7.4').FileName | Should -Be 'php-7.4.33-nts-Win32-vc15-x64.zip'
        }
        It 'ignores thread-safe (non-nts) zips' {
            (Select-PhpZipForMinor -Index $script:idx -Minor '8.2').FileName | Should -Match '-nts-'
        }
        It 'returns null for a minor not present' {
            Select-PhpZipForMinor -Index $script:idx -Minor '9.9' | Should -BeNullOrEmpty
        }
    }

    Context 'Resolve-LatestPhpMinor' {
        It 'returns the highest minor' {
            Resolve-LatestPhpMinor -Index $script:idx | Should -Be '8.4'
        }
    }

    Context 'Get-Sha256FromSumFile' {
        BeforeAll {
            $script:sums = @'
2ff43fea9a243085493b48c7c47152c0678cff0b05c61a3b4f4b43ba22de212c  php-8.5.7-nts-Win32-vs17-x64.zip
1111111111111111111111111111111111111111111111111111111111111111  php-8.2.31-nts-Win32-vs16-x64.zip
'@
        }
        It 'returns the hash for a filename' {
            Get-Sha256FromSumFile -Content $script:sums -FileName 'php-8.2.31-nts-Win32-vs16-x64.zip' | Should -Be '1111111111111111111111111111111111111111111111111111111111111111'
        }
        It 'is case-insensitive on the filename' {
            Get-Sha256FromSumFile -Content $script:sums -FileName 'PHP-8.5.7-NTS-Win32-vs17-x64.zip' | Should -Be '2ff43fea9a243085493b48c7c47152c0678cff0b05c61a3b4f4b43ba22de212c'
        }
        It 'returns null when the file is absent' {
            Get-Sha256FromSumFile -Content $script:sums -FileName 'php-9.9.9-nts-Win32-vs17-x64.zip' | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-PhpInstallPlan' {
        It 'builds a releases plan with the resolved URL' {
            $p = ConvertTo-PhpInstallPlan -Minor '8.3' -ReleasesIndex $script:idx
            $p.Version  | Should -Be '8.3.31'
            $p.Source   | Should -Be 'releases'
            $p.Url      | Should -Be 'https://windows.php.net/downloads/releases/php-8.3.31-nts-Win32-vs16-x64.zip'
            $p.ShaUrl   | Should -Be 'https://windows.php.net/downloads/releases/sha256sum.txt'
        }
        It 'falls back to the archives index when not in releases' {
            $arc = '<a href="php-7.2.34-nts-Win32-vc15-x64.zip">php-7.2.34-nts-Win32-vc15-x64.zip</a>'
            $p = ConvertTo-PhpInstallPlan -Minor '7.2' -ReleasesIndex $script:idx -ArchivesIndex $arc
            $p.Source  | Should -Be 'archives'
            $p.Url     | Should -Be 'https://windows.php.net/downloads/releases/archives/php-7.2.34-nts-Win32-vc15-x64.zip'
        }
        It 'returns null when the minor is nowhere' {
            ConvertTo-PhpInstallPlan -Minor '9.9' -ReleasesIndex $script:idx -ArchivesIndex '' | Should -BeNullOrEmpty
        }
    }

    Context 'Install-Php argument validation (no network)' {
        It 'rejects a patch-level version before any download' {
            { Install-Php -Query '8.2.13' } | Should -Throw '*minor like 8.2*'
        }
        It 'rejects garbage' {
            { Install-Php -Query 'banana' } | Should -Throw '*invalid version*'
        }
    }
}

Describe 'Get-PhpvmTrayModel' {
    BeforeAll {
        $script:gbase = Join-Path ([System.IO.Path]::GetTempPath()) ("phpvm-gui-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        $d82 = Join-Path $script:gbase 'p82'
        $d81 = Join-Path $script:gbase 'p81'
        New-Item -ItemType Directory -Path (Join-Path $d82 'ext'), $d81 -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d82 'ext\php_xdebug.dll') -Value 'x' -Encoding ASCII
        $script:gInstalls = @(
            [pscustomobject]@{ Version='8.2.31'; Minor='8.2'; Path=(Join-Path $d82 'php.exe'); Dir=$d82; Source='phpvm';  Active=$false }
            [pscustomobject]@{ Version='8.1.34'; Minor='8.1'; Path=(Join-Path $d81 'php.exe'); Dir=$d81; Source='Manual'; Active=$false }
        )
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:gbase) {
            Remove-Item -LiteralPath $script:gbase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'marks the global-default minor active' {
        $m = Get-PhpvmTrayModel -Installs $script:gInstalls -GlobalMinor '8.2'
        ($m.Rows | Where-Object { $_.Minor -eq '8.2' }).Active | Should -BeTrue
        ($m.Rows | Where-Object { $_.Minor -eq '8.1' }).Active | Should -BeFalse
    }
    It 'detects xdebug from ext\php_xdebug.dll' {
        $m = Get-PhpvmTrayModel -Installs $script:gInstalls -GlobalMinor '8.2'
        ($m.Rows | Where-Object { $_.Minor -eq '8.2' }).HasXdebug | Should -BeTrue
        ($m.Rows | Where-Object { $_.Minor -eq '8.1' }).HasXdebug | Should -BeFalse
    }
    It 'marks nothing active when the global default is unset' {
        $m = Get-PhpvmTrayModel -Installs $script:gInstalls -GlobalMinor $null
        @($m.Rows | Where-Object { $_.Active }).Count | Should -Be 0
    }
    It 'returns one row per install' {
        (Get-PhpvmTrayModel -Installs $script:gInstalls -GlobalMinor '8.2').Rows.Count | Should -Be 2
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
    It 'matches by minor - highest patch wins' {
        (Find-PhpInstallByQuery -Query '8.2' -Installs $script:fakeInstalls).Version | Should -Be '8.2.15'
    }
    It 'returns null for unknown' {
        Find-PhpInstallByQuery -Query '9.9' -Installs $script:fakeInstalls | Should -BeNullOrEmpty
    }
    It 'strips php prefix' {
        (Find-PhpInstallByQuery -Query 'php8.1' -Installs $script:fakeInstalls).Minor | Should -Be '8.1'
    }
}

Describe 'Resolve-PhpvmWhich' {
    BeforeAll {
        $script:fakeInstalls = @(
            [pscustomobject]@{ Version='8.2.15'; Minor='8.2'; Path='C:\php\82\php.exe'; Dir='C:\php\82'; Source='Manual'; Active=$false }
            [pscustomobject]@{ Version='8.1.27'; Minor='8.1'; Path='C:\php\81\php.exe'; Dir='C:\php\81'; Source='Manual'; Active=$false }
        )
    }
    It 'returns the php.exe path for a matching minor' {
        Resolve-PhpvmWhich -Query '8.2' -Installs $script:fakeInstalls | Should -Be 'C:\php\82\php.exe'
    }
    It 'accepts a php-prefixed query' {
        Resolve-PhpvmWhich -Query 'php8.1' -Installs $script:fakeInstalls | Should -Be 'C:\php\81\php.exe'
    }
    It 'returns null on a miss' {
        Resolve-PhpvmWhich -Query '9.9' -Installs $script:fakeInstalls | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-PhpInstallsJson' {
    BeforeAll {
        $script:fakeInstalls = @(
            [pscustomobject]@{ Version='8.2.15'; Minor='8.2'; Path='C:\php\82\php.exe'; Dir='C:\php\82'; Source='Manual'; Active=$true }
            [pscustomobject]@{ Version='8.1.27'; Minor='8.1'; Path='C:\php\81\php.exe'; Dir='C:\php\81'; Source='Manual'; Active=$false }
        )
    }
    It 'emits valid JSON that round-trips' {
        $parsed = (ConvertTo-PhpInstallsJson -Installs $script:fakeInstalls) | ConvertFrom-Json
        @($parsed).Count | Should -Be 2
    }
    It 'carries version, path, and active flag' {
        $parsed = (ConvertTo-PhpInstallsJson -Installs $script:fakeInstalls) | ConvertFrom-Json
        $parsed[0].version | Should -Be '8.2.15'
        $parsed[0].path    | Should -Be 'C:\php\82\php.exe'
        $parsed[0].active  | Should -BeTrue
        $parsed[1].active  | Should -BeFalse
    }
    It 'always produces a JSON array, even for one install' {
        $json = ConvertTo-PhpInstallsJson -Installs @($script:fakeInstalls[0])
        $json.TrimStart()[0] | Should -Be '['
        @(($json | ConvertFrom-Json)).Count | Should -Be 1
    }
    It 'returns [] for no installs' {
        ConvertTo-PhpInstallsJson -Installs @() | Should -Be '[]'
    }
}
