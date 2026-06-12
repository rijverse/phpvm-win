# lib/gui.ps1 - system-tray GUI. WinForms NotifyIcon, no extra deps (ships with
# .NET Framework on PS 5.1 and the Desktop runtime on PS 7). Right-click menu
# lists installed PHPs and switches the global default. WinForms wants STA - the
# phpvm.cmd launcher already is.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'switch.ps1')

# script scope so the click/timer handlers can reach these. Seeded to $null so
# the guards in Remove-PhpvmTray don't trip StrictMode on an unset var.
$script:PhpvmTrayNotify = $null
$script:PhpvmTrayMenu   = $null
$script:PhpvmTrayTimer  = $null

function Get-PhpvmTrayModel {
    # the menu rows: version, active marker (= the global default), xdebug hint.
    # No WinForms in here so it can be tested on its own.
    [CmdletBinding()]
    param(
        [object[]]$Installs,
        [string]$GlobalMinor
    )
    if (-not $Installs) { $Installs = Get-AllPhpInstalls }
    if (-not $PSBoundParameters.ContainsKey('GlobalMinor')) {
        $meta = Get-PhpvmActiveMeta
        $GlobalMinor = if ($meta -and $meta.ContainsKey('minor')) { $meta['minor'] } else { $null }
    }
    $rows = @()
    foreach ($i in $Installs) {
        $hasXdebug = Test-Path -LiteralPath (Join-Path $i.Dir 'ext\php_xdebug.dll')
        $rows += [pscustomobject]@{
            Version   = $i.Version
            Minor     = $i.Minor
            Source    = $i.Source
            Path      = $i.Path
            Dir       = $i.Dir
            Active    = [bool]($GlobalMinor -and ($i.Minor -eq $GlobalMinor))
            HasXdebug = [bool]$hasXdebug
        }
    }
    return [pscustomobject]@{ Rows = @($rows); GlobalMinor = $GlobalMinor }
}

function Update-PhpvmTrayMenu {
    # rebuild the whole menu from scratch each time - cheaper than diffing it.
    $menu = $script:PhpvmTrayMenu
    $menu.Items.Clear()

    $verVar = Get-Variable -Name PhpvmVersion -ErrorAction SilentlyContinue
    $ver = if ($verVar) { $verVar.Value } else { '' }
    $header = New-Object System.Windows.Forms.ToolStripMenuItem ("phpvm $ver".TrimEnd())
    $header.Enabled = $false
    $menu.Items.Add($header) | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $model = Get-PhpvmTrayModel
    $rows = @($model.Rows)
    if ($rows.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem 'no PHP installs found'
        $none.Enabled = $false
        $menu.Items.Add($none) | Out-Null
    } else {
        foreach ($r in $rows) {
            $label = "PHP $($r.Version)  ($($r.Source))"
            if ($r.HasXdebug) { $label += '  [xdebug]' }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
            $item.Checked = $r.Active
            $item.Tag = $r.Minor
            $item.Add_Click({
                $minor = $this.Tag
                try {
                    Switch-PhpvmTo -Query $minor -Quiet | Out-Null
                    $script:PhpvmTrayNotify.ShowBalloonTip(2000, 'phpvm', "Global PHP set to $minor", [System.Windows.Forms.ToolTipIcon]::Info)
                } catch {
                    $script:PhpvmTrayNotify.ShowBalloonTip(3000, 'phpvm', "Switch failed: $($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
                }
                Update-PhpvmTrayMenu
            })
            $menu.Items.Add($item) | Out-Null
        }
    }

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh'
    $refresh.Add_Click({ Update-PhpvmTrayMenu })
    $menu.Items.Add($refresh) | Out-Null

    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open versions folder'
    $openItem.Add_Click({
        $dir = Get-PhpvmVersionsDir
        if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe $dir }
    })
    $menu.Items.Add($openItem) | Out-Null

    $exit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $exit.Add_Click({
        if ($script:PhpvmTrayTimer) { $script:PhpvmTrayTimer.Stop() }
        if ($script:PhpvmTrayNotify) { $script:PhpvmTrayNotify.Visible = $false; $script:PhpvmTrayNotify.Dispose() }
        [System.Windows.Forms.Application]::Exit()
    })
    $menu.Items.Add($exit) | Out-Null
}

function New-PhpvmTray {
    # icon + menu only, no message loop yet
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $script:PhpvmTrayNotify = New-Object System.Windows.Forms.NotifyIcon
    $script:PhpvmTrayNotify.Icon = [System.Drawing.SystemIcons]::Application
    $script:PhpvmTrayNotify.Text = 'phpvm'
    $script:PhpvmTrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:PhpvmTrayNotify.ContextMenuStrip = $script:PhpvmTrayMenu
    $script:PhpvmTrayNotify.Add_DoubleClick({
        Update-PhpvmTrayMenu
        $script:PhpvmTrayMenu.Show([System.Windows.Forms.Cursor]::Position)
    })
    Update-PhpvmTrayMenu
}

function Remove-PhpvmTray {
    if ($script:PhpvmTrayTimer)  { try { $script:PhpvmTrayTimer.Stop(); $script:PhpvmTrayTimer.Dispose() } catch { } }
    if ($script:PhpvmTrayNotify) { try { $script:PhpvmTrayNotify.Visible = $false; $script:PhpvmTrayNotify.Dispose() } catch { } }
    $script:PhpvmTrayTimer = $null
    $script:PhpvmTrayNotify = $null
    $script:PhpvmTrayMenu = $null
}

function Invoke-PhpvmTray {
    [CmdletBinding()]
    param()

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        Write-Host "phpvm: the tray GUI needs an STA thread."
        Write-Host "       Launch it with 'phpvm --window' (the phpvm.cmd wrapper is STA),"
        Write-Host "       or run: powershell.exe -STA -File <phpvm.ps1> --window"
        return 2
    }

    try {
        New-PhpvmTray
    } catch {
        Write-Host "phpvm: could not start the tray GUI: $($_.Exception.Message)"
        return 1
    }

    $script:PhpvmTrayNotify.Visible = $true

    # poll every few seconds so a switch from another window updates the checkmark.
    # Skip while the menu is open - rebuilding would yank items out from under the
    # cursor mid-navigation.
    $script:PhpvmTrayTimer = New-Object System.Windows.Forms.Timer
    $script:PhpvmTrayTimer.Interval = 5000
    $script:PhpvmTrayTimer.Add_Tick({
        if ($script:PhpvmTrayMenu -and -not $script:PhpvmTrayMenu.Visible) { Update-PhpvmTrayMenu }
    })
    $script:PhpvmTrayTimer.Start()

    $script:PhpvmTrayNotify.ShowBalloonTip(1500, 'phpvm', 'Running in the system tray. Right-click the icon.', [System.Windows.Forms.ToolTipIcon]::Info)

    try {
        [System.Windows.Forms.Application]::Run()
    } finally {
        Remove-PhpvmTray
    }
    return 0
}
