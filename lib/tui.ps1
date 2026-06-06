# lib/tui.ps1 - arrow-key picker
# Plain System.Console; ANSI for color + cursor. No external deps.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'detect.ps1')
. (Join-Path $PSScriptRoot 'switch.ps1')
. (Join-Path $PSScriptRoot 'project.ps1')

function Test-PhpvmTuiSupported {
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    if ($env:PHPVM_NO_TUI) { return $false }
    try { $null = [Console]::WindowWidth } catch { return $false }
    return $true
}

function _PhpvmAnsi {
    param([string]$Seq)
    [Console]::Write([char]27 + $Seq)
}

function _PhpvmRender {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][int]$Index,
        [object]$Active
    )
    [Console]::Clear()
    $bar  = '-' * 56
    $top  = "+$bar+"
    $mid  = "+$bar+"
    $bot  = "+$bar+"

    Write-Host $top
    Write-Host "| phpvm - select PHP version" -NoNewline
    Write-Host (' ' * (57 - 27)) -NoNewline
    Write-Host '|'
    Write-Host $mid

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        $marker = if ($it.Active) { '*' } else { ' ' }
        $cursor = if ($i -eq $Index) { '>' } else { ' ' }
        $line = "{0} {1} {2,-8}  {3,-8}  {4}" -f $cursor, $marker, $it.Version, $it.Source, $it.Dir
        if ($line.Length -gt 54) { $line = $line.Substring(0, 54) }
        $pad = 54 - $line.Length
        if ($i -eq $Index) {
            Write-Host "| " -NoNewline
            _PhpvmAnsi '[7m'   # reverse
            Write-Host $line -NoNewline
            _PhpvmAnsi '[0m'
            Write-Host ((' ' * $pad) + ' |')
        } else {
            Write-Host "| $line$(' ' * $pad) |"
        }
    }

    Write-Host $mid
    Write-Host "| ^/v move   Enter switch   p set-project   q quit         |"
    Write-Host $bot
}

function Invoke-PhpvmTui {
    [CmdletBinding()]
    param()

    if (-not (Test-PhpvmTuiSupported)) {
        throw "phpvm: TUI requires ConsoleHost (cmd.exe / Windows Terminal). Use --list / --set instead."
    }

    $items = Get-AllPhpInstalls
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "phpvm: no PHP installations found."
        return
    }

    $idx = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Active) { $idx = $i; break }
    }

    $cursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            _PhpvmRender -Items $items -Index $idx -Active $null
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($idx -gt 0) { $idx-- } }
                'DownArrow' { if ($idx -lt $items.Count - 1) { $idx++ } }
                'Enter' {
                    [Console]::Clear()
                    Set-PhpvmActive -Install $items[$idx]
                    return
                }
                'Escape' { [Console]::Clear(); return }
                default {
                    switch ($key.KeyChar) {
                        'k' { if ($idx -gt 0) { $idx-- } }
                        'j' { if ($idx -lt $items.Count - 1) { $idx++ } }
                        'q' { [Console]::Clear(); return }
                        'p' {
                            $file = Write-PhpVersionFile -Version $items[$idx].Minor
                            [Console]::Clear()
                            Write-Host "phpvm: wrote $file ($($items[$idx].Minor))"
                            return
                        }
                    }
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
    }
}
