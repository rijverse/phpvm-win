# phpvm-windows

> Per-project PHP version manager for Windows. Sister project to [phpvm](https://github.com/rijoanul-shanto/phpvm) (Linux/macOS).

[![CI](https://github.com/rijoanul-shanto/phpvm-win/actions/workflows/ci.yml/badge.svg)](https://github.com/rijoanul-shanto/phpvm-win/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`phpvm` discovers every PHP install on your machine — Scoop, XAMPP, Laragon, WAMP, or hand-extracted zips — and lets you swap the active version instantly without editing `PATH`.

## What it does

- Lists every PHP install on disk and marks the active one.
- Switches active PHP in under a second via a `.cmd` shim. No `PATH` churn.
- Auto-switches on `cd` based on `.php-version` or `composer.json` `require.php`.

## Install

One-liner (PowerShell, no admin required):

```powershell
irm https://raw.githubusercontent.com/rijoanul-shanto/phpvm-win/main/install.ps1 | iex
```

Or clone and run manually:

```powershell
git clone https://github.com/rijoanul-shanto/phpvm-win
cd phpvm-win
.\install.ps1
```

The installer:

1. Creates `%USERPROFILE%\.phpvm\{bin,shim}`.
2. Prepends both dirs to user `PATH` (idempotent).
3. Broadcasts `WM_SETTINGCHANGE` so new shells pick up `PATH` without logout.
4. Optionally enables the auto-switch hook and sets an initial active version.

## Quick start

```powershell
phpvm                 # arrow-key picker (TUI)
phpvm --list          # list installed PHP versions
phpvm --current       # show active
phpvm --set 8.2       # switch to PHP 8.2 (highest matching minor)
phpvm --set-project 8.2   # write .php-version in current dir
phpvm --doctor        # diagnose install
```

## Auto-switch

Drop a `.php-version` in any project root:

```
8.2
```

…or rely on `composer.json`:

```json
{
  "require": { "php": "^8.2" }
}
```

Enable the hook once:

```powershell
phpvm --enable-hook
```

On every `cd`, `phpvm` walks up looking for `.php-version` or `composer.json` and switches if the active minor doesn't match.

## Supported PHP sources

| Source | Detection |
| --- | --- |
| Scoop | `scoop list` + `scoop prefix` |
| XAMPP | `C:\xampp\php` |
| Laragon | `C:\laragon\bin\php\php-*` |
| WAMP | `C:\wamp64\bin\php\php*` |
| Manual | `C:\php*`, `C:\tools\php*`, `%LOCALAPPDATA%\Programs\php*` |
| Custom | Set `$env:PHPVM_SEARCH_PATHS` (semicolon-separated globs) |

## Commands

| Flag | Behavior |
| --- | --- |
| _(none)_ | Launch TUI |
| `--list`, `-l` | List versions, mark active |
| `--current`, `-c` | Print active version + `php --version` |
| `--set <ver>`, `-s` | Switch to version |
| `--auto [--quiet] [--print] [dir]`, `-a` | Auto-switch from project |
| `--set-project <ver>`, `-p` | Write `.php-version` |
| `--enable-hook` | Install prompt hook |
| `--disable-hook` | Remove prompt hook |
| `--doctor` | Diagnose install |
| `--self-update [URL] [REF]` | Pull from git, re-run installer |
| `--version`, `-v` | Print version |
| `--help`, `-h` | Help |

## Troubleshooting

### `phpvm` not found after install

Reload `PATH` in the current shell:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
```

Or open a fresh terminal.

### `running scripts is disabled on this system`

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### Antivirus quarantines the `.cmd` shim

Add `%USERPROFILE%\.phpvm\shim` to your AV exclusions.

### Active PHP won't change

Run `phpvm --doctor`. Common causes: shell PATH stale (open new terminal), `PHPRC` env var hijacking the binary, or shim file locked by a running `php.exe` (kill it).

## Comparison to Linux phpvm

| | Linux/macOS | Windows |
| --- | --- | --- |
| Mechanism | symlink in `~/.local/bin` | `.cmd` shim in `%USERPROFILE%\.phpvm\shim` |
| Auto-switch hook | `chpwd_functions` (zsh) / `PROMPT_COMMAND` (bash) | `prompt` function override |
| Discovery | Homebrew + dir scan | Scoop + dir scan |
| Project detection | Identical | Identical |
| CLI surface | Identical | Identical |

## Uninstall

```powershell
phpvm --uninstall      # or run uninstall.ps1 directly
```

Removes the shim, strips `PATH`, removes the hook. **Does not** touch any PHP installation.

## License

MIT — see [LICENSE](LICENSE).
