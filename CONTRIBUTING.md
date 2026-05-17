# Contributing

Thanks for your interest in `phpvm-windows`.

## Dev setup

Requirements:

- Windows 10 1607+ or Windows 11
- PowerShell 5.1 or 7.x
- Pester v5 (`Install-Module Pester -Force -SkipPublisherCheck`)
- Git

Clone and run tests:

```powershell
git clone https://github.com/OWNER/phpvm-windows
cd phpvm-windows
Invoke-Pester ./tests
```

## Project layout

| Path | Purpose |
| --- | --- |
| `phpvm.ps1` | CLI entry + dispatcher |
| `lib/detect.ps1` | PHP discovery |
| `lib/switch.ps1` | Shim rewrite |
| `lib/project.ps1` | `.php-version` + composer constraint parser |
| `lib/tui.ps1` | Arrow-key picker |
| `lib/doctor.ps1` | Diagnostics |
| `install.ps1` | Installer |
| `uninstall.ps1` | Uninstaller |
| `profile/phpvm-hook.ps1` | Prompt auto-switch hook |
| `tests/` | Pester suite |

## Coding style

- 4-space indent, LF line endings (CRLF for `.cmd`).
- Approved verbs for functions (`Get-`, `Set-`, `Test-`, etc).
- Cmdlet-style param blocks with `[CmdletBinding()]` where helpful.
- No emoji in code or output unless behind a `-Pretty` flag.
- Error messages: short, action-oriented, prefix with `phpvm:` so they pipe-grep cleanly.

## Pull requests

1. Branch from `main`.
2. Add or update Pester tests for any behavior change.
3. Update `CHANGELOG.md` under `## [Unreleased]`.
4. Keep PRs focused; one feature or fix per PR.

## Reporting bugs

Include in the issue:

- Output of `phpvm --doctor`
- `$PSVersionTable`
- Windows build (`[System.Environment]::OSVersion.Version`)
- Exact command + full error
