# uninstall.ps1 - remove phpvm-windows
# Leaves all PHP installations untouched.

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$KeepActiveLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PHPVM_ROOT relocates the install (set by install.ps1 -Prefix); mirror it here.
$installRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phpvm'
if ($env:PHPVM_ROOT) { $installRoot = $env:PHPVM_ROOT }

if (-not $Yes) {
    $ans = Read-Host "phpvm: remove $installRoot and strip PATH entries? [y/N]"
    if ($ans -notmatch '^[Yy]') {
        Write-Host "phpvm: aborted."
        exit 0
    }
}

# Disable hook if installed
$installedCli = Join-Path $installRoot 'bin\phpvm.ps1'
if (Test-Path -LiteralPath $installedCli) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installedCli '--disable-hook'
    } catch {
        Write-Warning "phpvm: --disable-hook failed: $($_.Exception.Message)"
    }
}

# Strip user PATH entries. Read/write the registry value raw: going through
# [Environment]::Get/SetEnvironmentVariable would expand and re-save every entry
# as REG_SZ, flattening %VAR% references other tools keep in the user PATH.
$binDir  = Join-Path $installRoot 'bin'
$shimDir = Join-Path $installRoot 'shim'
$envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
if ($envKey) {
    try {
        $current = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($current) {
            $parts = $current -split ';' | Where-Object {
                if (-not $_) { return $false }
                $expanded = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
                ($expanded -ine $binDir.TrimEnd('\')) -and ($expanded -ine $shimDir.TrimEnd('\'))
            }
            $new = $parts -join ';'
            if ($new -ne $current) {
                $envKey.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                Write-Host "phpvm: removed phpvm entries from user PATH."
            }
        }
    } finally { $envKey.Close() }
}

# Drop the persisted PHPVM_ROOT if it points at the root being removed
$persistedRoot = [Environment]::GetEnvironmentVariable('PHPVM_ROOT', 'User')
if ($persistedRoot -and ($persistedRoot.TrimEnd('\') -ieq $installRoot.TrimEnd('\'))) {
    [Environment]::SetEnvironmentVariable('PHPVM_ROOT', $null, 'User')
    Write-Host "phpvm: removed persisted PHPVM_ROOT."
}

# Preserve .active log if requested
if ($KeepActiveLog) {
    $activeFile = Join-Path $shimDir '.active'
    if (Test-Path -LiteralPath $activeFile) {
        $backup = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'phpvm-last-active.txt'
        Copy-Item -LiteralPath $activeFile -Destination $backup -Force
        Write-Host "phpvm: preserved active log -> $backup"
    }
}

# Remove per-version junctions FIRST. A recursive delete would otherwise follow
# them into the real PHP installs and wipe them out - the junctions under
# versions\<minor> point straight at the actual install dirs.
$versionsDir = Join-Path $installRoot 'versions'
if (Test-Path -LiteralPath $versionsDir) {
    Get-ChildItem -LiteralPath $versionsDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LinkType -eq 'Junction' -or $_.LinkType -eq 'SymbolicLink') {
            try { [System.IO.Directory]::Delete($_.FullName, $false) }
            catch { & cmd /c rmdir "$($_.FullName)" 2>$null }
        }
    }
}

if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
    Write-Host "phpvm: removed $installRoot"
}

# Broadcast PATH change
try {
    if (-not ('PhpvmUninstaller.NativeMethods' -as [Type])) {
        Add-Type -Namespace PhpvmUninstaller -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
"@
    }
    $result = [System.UIntPtr]::Zero
    [PhpvmUninstaller.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result
    ) | Out-Null
} catch { }

Write-Host ''
Write-Host "phpvm: uninstall complete."
Write-Host "PHP installations were left untouched - uninstall them via Scoop / Chocolatey / manually."
