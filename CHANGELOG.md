# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] - 2026-06-07

### Added
- `phpvm --window` (alias `--tray`): a system-tray GUI on the WinForms
  `NotifyIcon`, no extra dependencies. Right-click for the installed versions
  (global default checked, `[xdebug]` flagged), click one to switch. Needs an STA
  thread - the `phpvm.cmd` launcher is one; `pwsh` (MTA) is told how to relaunch.

## [1.3.0] - 2026-06-06

### Added
- `phpvm install <ver>`: download an NTS x64 PHP build from windows.php.net for a
  minor (e.g. `8.3`) or `latest`, verify the published SHA256, extract to
  `%USERPROFILE%\.phpvm\php\<minor>`, and register a `versions\<minor>` junction.
  - `--print` resolves the URL, hash file, and target dir without downloading.
  - `--force` reinstalls over an existing copy; otherwise an existing minor is
    left in place and just (re)registered.
  - `latest` resolves the highest minor from the release index.
  - Patch-level args (`8.2.13`) are rejected; install works on minors.
  - Scoop is detected and suggested as an alternative, never required.
- Discovery now scans `%USERPROFILE%\.phpvm\php\<minor>` (source `phpvm`), so
  installed builds appear in `--list` and resolve for `global` / `shell`
  regardless of `PHPVM_SEARCH_PATHS`.

## [1.2.0] - 2026-06-06

### Added
- Per-shell switching. PHP is resolved at call time from three layers: shell
  (`$env:PHPVM_SHELL_VERSION`) > project (`$env:PHPVM_AUTO_VERSION`) > global
  (the persisted default). A `cd` in one terminal no longer changes PHP in
  another.
- Per-version directory junctions under `%USERPROFILE%\.phpvm\versions\<minor>`,
  the Windows analog of Linux's per-version binaries. No admin rights required.
- A static resolver `php.cmd` shim that does the layered lookup with no
  PowerShell spawn (fast `php` startup).
- `phpvm global <ver>` (alias `--set`, `-s`) sets the persisted default.
- `phpvm local <ver>` (alias `--set-project`, `-p`) writes `.php-version`.
- `phpvm shell <ver>` / `phpvm shell --unset` pin PHP for the current terminal,
  via a `phpvm` wrapper function installed by `--enable-hook` (a child process
  cannot set its parent's environment, so the wrapper runs in-session).
- `phpvm --current` now prints the effective version plus the shell/project/global
  breakdown and an inactive-shim hint when the shim is shadowed on PATH.
- `phpvm --doctor` gains a "Per-shell switching" section (shim status, registered
  junctions, current layer state).
- `PHPVM_ROOT` environment override relocates the install (and isolates tests);
  the resolver shim honors it too.
- Self-heal: the prompt hook keeps the shim dir ahead of any other `php.exe` on
  the process PATH.

### Changed
- The `cd`-hook now sets `$env:PHPVM_AUTO_VERSION` for the current terminal
  instead of rewriting a single global shim. Old flags (`--set`, `--set-project`)
  remain as aliases, so the flag surface is backward compatible.
- The `.active` meta is written as ASCII (no BOM) so the resolver shim parses it.

### Fixed
- `uninstall.ps1` now removes the per-version junctions before the recursive
  delete of `%USERPROFILE%\.phpvm`. Without this a `Remove-Item -Recurse` would
  follow the junctions into the real PHP installs and delete them.

## [1.1.0] - 2026-06-06

### Added
- `phpvm which <ver>`: print the bare `php.exe` path for a version query
  (accepts `8.2` and `php8.2`), stdout only, exit 1 with a stderr message on miss.
- `phpvm --list --paths`: list installs with their absolute `php.exe` path.
- `phpvm --list --json`: emit `[{version, path, active}]` (always a JSON array).
- `docs/IDE.md`: wiring PhpStorm and VS Code to phpvm on Windows.

### Fixed
- `Get-PhpvmRoot` assigned to `$home`, colliding with PowerShell's read-only
  `$HOME` automatic variable and throwing on every command that discovers PHP.
- `Get-AllPhpInstalls` version sort used a broken padding expression that
  produced strings like `8.2.26.` and failed `[version]` casting whenever a real
  install was present.
- `Get-AllPhpInstalls` collapsed to a scalar with exactly one install, so
  `--list` threw on `.Count`. It now always returns an array.
- `$rest` argument array collapsed to a scalar under `Set-StrictMode`, breaking
  single-argument commands such as `--set 8.2` and `which 8.2`.

## [1.0.1] - 2026-06-06

### Fixed
- Replace placeholder repository URLs (`OWNER/phpvm-windows`, `rijoanul-shanto/*`)
  with the canonical `rijverse/phpvm-win` and sister `rijverse/phpvm` across
  `install.ps1`, `README.md`, `CHANGELOG.md`, and `CONTRIBUTING.md`.
- Fix the CI badge URL in `README.md`.

## [1.0.0] - 2026-05-17

### Added
- PHP discovery: Scoop probe + directory scan (XAMPP, Laragon, WAMP, manual).
- Active switch via `.cmd` shim in `%USERPROFILE%\.phpvm\shim`.
- Project detection from `.php-version` and `composer.json` (`require.php`).
- Composer constraint parser (caret, tilde, range, pipe alternatives).
- Prompt-function auto-switch hook (PowerShell 5.1 + 7.x).
- Arrow-key TUI picker.
- Doctor diagnostics with pass/fail count + fix hints.
- Installer (`install.ps1`) + uninstaller (`uninstall.ps1`).
- Self-update from git.
- Pester v5 test suite.
- CI on `windows-latest` + `windows-2019`, PowerShell 5.1 + 7.x.

[Unreleased]: https://github.com/rijverse/phpvm-win/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/rijverse/phpvm-win/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/rijverse/phpvm-win/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/rijverse/phpvm-win/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/rijverse/phpvm-win/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/rijverse/phpvm-win/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/rijverse/phpvm-win/releases/tag/v1.0.0
