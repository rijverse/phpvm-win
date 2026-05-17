# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/OWNER/phpvm-windows/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/OWNER/phpvm-windows/releases/tag/v1.0.0
