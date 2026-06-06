# phpvm-windows

> Per-project PHP version manager for Windows. Sister project to [phpvm](https://github.com/rijverse/phpvm) (Linux/macOS).

[![CI](https://github.com/rijverse/phpvm-win/actions/workflows/ci.yml/badge.svg)](https://github.com/rijverse/phpvm-win/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`phpvm` discovers every PHP install on your machine (Scoop, XAMPP, Laragon, WAMP, or hand-extracted zips) and lets you swap the active version instantly without editing `PATH`.

## What it does

- Lists every PHP install on disk and marks the active one.
- Switches active PHP in under a second via a `.cmd` shim. No `PATH` churn.
- Auto-switches on `cd` based on `.php-version` or `composer.json` `require.php`.

## Install

One-liner (PowerShell, no admin required):

```powershell
irm https://raw.githubusercontent.com/rijverse/phpvm-win/main/install.ps1 | iex
```

Or clone and run manually:

```powershell
git clone https://github.com/rijverse/phpvm-win
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
phpvm --current       # show effective version + the three layers
phpvm global 8.2      # set the global default (highest matching minor)
phpvm shell 8.2       # pin PHP for THIS terminal only (needs the hook)
phpvm local 8.2       # write .php-version in current dir
phpvm --doctor        # diagnose install
```

`--set` / `--set-project` still work as aliases for `global` / `local`.

## Auto-switch

Drop a `.php-version` in any project root:

```
8.2
```

...or rely on `composer.json`:

```json
{
  "require": { "php": "^8.2" }
}
```

Enable the hook once:

```powershell
phpvm --enable-hook
```

On every `cd`, the hook walks up looking for `.php-version` or `composer.json` and
sets `$env:PHPVM_AUTO_VERSION` for the current terminal only. This is the project
layer (see [Per-shell switching](#per-shell-switching)); it never changes the
global default or other terminals. A `phpvm shell` pin always wins over it.

## Editor / IDE setup

IDEs launch `php.exe` directly and do not follow the shim. Point them at a
concrete path with `phpvm which <ver>` or `phpvm --list --json`. See
[docs/IDE.md](docs/IDE.md) for PhpStorm and VS Code.

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
| `--list --paths` | List versions with absolute `php.exe` paths |
| `--list --json` | List as JSON (`[{version, path, active}]`) |
| `which <ver>` | Print the `php.exe` path for a version |
| `install <ver> [--print] [--force]` | Download + install NTS x64 PHP (minor or `latest`) |
| `--current`, `-c` | Effective version + shell/project/global layers |
| `global <ver>` | Set the global default (alias: `--set`, `-s`) |
| `local <ver>` | Pin this dir via `.php-version` (alias: `--set-project`, `-p`) |
| `shell <ver>` | Pin PHP for this terminal only (needs the hook) |
| `shell --unset` | Remove this terminal's pin |
| `--auto [--quiet] [--print] [dir]`, `-a` | Resolve project PHP (used by the hook) |
| `--enable-hook` | Install auto-switch hook + `phpvm` wrapper |
| `--disable-hook` | Remove prompt hook |
| `--window`, `--tray` | Launch the system-tray GUI |
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

## Installing PHP

If a version is not on disk, phpvm can fetch it:

```powershell
phpvm install 8.3          # download + verify + extract PHP 8.3 (highest patch)
phpvm install latest       # the newest minor on windows.php.net
phpvm install 8.3 --print  # show the URL + target dir, download nothing
phpvm install 8.3 --force  # reinstall over an existing copy
```

It downloads the NTS x64 build from windows.php.net, verifies the published
SHA256, extracts to `%USERPROFILE%\.phpvm\php\<minor>`, and registers a
per-version junction so `phpvm global 8.3` / `phpvm shell 8.3` can use it. Pass a
minor (`8.3`), not a patch (`8.3.14`); the latest patch of that minor is
installed. If Scoop is present, `scoop install php` is suggested as an
alternative but never required.

## Per-shell switching

PHP is resolved at call time from three layers, highest priority first:

1. **shell** - `$env:PHPVM_SHELL_VERSION`, set by `phpvm shell <ver>`, lives only
   in the current terminal.
2. **project** - `$env:PHPVM_AUTO_VERSION`, set by the `cd`-hook from
   `.php-version` / `composer.json`.
3. **global** - the persisted default set by `phpvm global <ver>`.

A `.cmd` resolver shim reads these and dispatches to a per-version directory
junction (`%USERPROFILE%\.phpvm\versions\<minor>`), so a `cd` in one terminal
never changes PHP in another. Junctions need no admin rights.

Because a child process cannot set its parent's environment, `phpvm shell` is
handled by a `phpvm` wrapper function that `--enable-hook` installs into your
profile. Without the hook, `phpvm shell` prints how to enable it.

```powershell
phpvm shell 8.1     # this terminal -> 8.1 (others unaffected)
phpvm shell         # show this terminal's pin
phpvm shell --unset # drop the pin; fall back to project/global
phpvm --current     # see which layer is winning
```

## System-tray GUI

```powershell
phpvm --window
```

Launches a tray icon (WinForms `NotifyIcon`, no extra dependencies). Right-click
to see installed versions with the global default checked and an `[xdebug]`
hint; click a version to switch the global default. The tray runs until you pick
Exit. To start it hidden in the background:

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-STA','-File',"$env:USERPROFILE\.phpvm\bin\phpvm.ps1",'--window'
```

The GUI needs an STA thread; the `phpvm` (cmd) launcher already is one. Under
PowerShell 7 (`pwsh`, which defaults to MTA), the command prints how to relaunch
in STA.

## Comparison to Linux phpvm

| | Linux/macOS | Windows |
| --- | --- | --- |
| Mechanism | `update-alternatives` symlink + per-shell `php` shim | resolver `.cmd` shim + per-version junctions in `%USERPROFILE%\.phpvm` |
| Per-shell switching | Yes (`phpvm shell`, three layers) | Yes (`phpvm shell`, three layers) |
| Auto-switch hook | `chpwd_functions` (zsh) / `PROMPT_COMMAND` (bash) | `prompt` function override + `phpvm` wrapper |
| Discovery | Homebrew + dir scan | Scoop + dir scan |
| Project detection | `.php-version` / `composer.json` | `.php-version` / `composer.json` |
| `install <ver>` | Yes (upstream repo) | Yes (windows.php.net, NTS x64) |
| GUI / tray | Yes (GTK) | Yes (WinForms tray) |

## Uninstall

```powershell
phpvm --uninstall      # or run uninstall.ps1 directly
```

Removes the shim, strips `PATH`, removes the hook. **Does not** touch any PHP installation.

## License

MIT - see [LICENSE](LICENSE).
