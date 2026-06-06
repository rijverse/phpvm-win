# phpvm-win Upgrade Plan

Bringing **phpvm-win** (currently v1.0.0) up to feature parity with the Linux/macOS **phpvm** (currently v2.6.1).

This is a working document. Drop it into the `phpvm-win` repo (for example as `UPGRADE-PLAN.md` or under `docs/`) and work the phases top to bottom. Typography here follows the project rule: no em dashes, no smart quotes, no Unicode ellipses. ASCII only.

---

## 1. Where each project stands

| | Linux/macOS `phpvm` | Windows `phpvm-win` |
| --- | --- | --- |
| Latest version | 2.6.1 | 1.0.0 |
| Switch mechanism | `update-alternatives` symlink (global) + per-shell `php` shim on `PATH` | single hard-coded `php.cmd` shim in `%USERPROFILE%\.phpvm\shim` |
| Per-shell switching | Yes (v2.5.0): `phpvm shell`, three-layer resolution | **No** (`cd` rewrites the one global shim, so it leaks across terminals) |
| Project pin | `.php-version` / `composer.json` | Same (already ported, parser is solid) |
| `cd`-hook | sets `PHPVM_AUTO_VERSION`, shim resolves it | rewrites the global shim directly (old model) |
| `which` | Yes (v2.6.0) | No |
| `--list --paths` / `--list --json` | Yes (v2.6.0) | No |
| `install <ver>` | Yes (v2.4.0), from upstream repo | No |
| GUI / tray | Yes (GTK tray + window) | Stub only (`--window` prints "not implemented") |
| `--current` layer breakdown | shell / project / global | single active line |
| Doctor | Yes | Yes (no per-shell section) |
| Self-update | Yes | Yes |
| Tests / CI | bash tests, Ubuntu matrix | Pester v5, PS 5.1 + 7 on windows-latest/2019 |

The Windows port is architecturally healthy. The detection layer (`lib/detect.ps1`), the composer constraint parser (`lib/project.ps1`), the TUI, doctor, installer, and self-update are all in good shape. The gap is the **feature set added to Linux after the fork** (roughly everything from phpvm v2.4.0 onward), plus a few stale-branding bugs.

---

## 2. Gap summary and effort

| Feature | Linux since | Windows effort | Phase |
| --- | --- | --- | --- |
| Stale repo links / placeholder URLs | n/a (bug) | Trivial | 0 |
| `phpvm which <ver>` | 2.6.0 | Small | 1 |
| `--list --paths` / `--list --json` | 2.6.0 | Small | 1 |
| `docs/IDE.md` (PhpStorm / VS Code on Windows) | 2.6.0 | Small | 1 |
| Per-shell switching (`shell`, three layers) | 2.5.0 | **Large** (core architecture) | 2 |
| `local` / `global` verbs (alias `--set` / `--set-project`) | 2.5.0 | Small (rename + alias) | 2 |
| `--current` layer breakdown | 2.5.0 | Small | 2 |
| Self-heal shim ordering on `PATH` | 2.5.1 / 2.6.1 | Medium | 2 |
| `phpvm install <ver>` | 2.4.0 | **Large** (PHP acquisition on Windows) | 3 |
| GUI / tray (`--window`) | 2.0.0 | **Large** (separate sub-project) | 4 |
| Confirmation lines, inactive-shim hint, doctor parity | 2.6.x | Small | 5 |

---

## 3. Guiding principles

1. **Faithful port, not identical mechanism.** Windows has no `update-alternatives`, no `sudo`, no GTK. Map each Linux concept to the closest Windows-native equivalent and keep the user-facing surface (flags, verbs, output shape) aligned.
2. **PowerShell-first and dependency-free.** No requirement on Scoop, Chocolatey, Python, or admin rights. Detect and use Scoop when present, never require it.
3. **Keep the Windows SemVer line.** phpvm-win has its own version track starting at 1.0.0. Do not try to match Linux version numbers. Ship the phases as the minor/major bumps proposed below.
4. **No behavior leaks across terminals.** This is the single most important correctness change. Today a `cd` in one window changes PHP everywhere. After Phase 2 it must not.

---

## 4. The core architecture change (Phase 2 in detail)

This is the heart of the upgrade, so it gets its own section.

### 4.1 Today's model (v1.0.0)

- `lib/switch.ps1 :: New-PhpvmShimContent` writes a `php.cmd` that hard-codes one target: `"C:\path\to\php.exe" %*`.
- `--set` rewrites that single shim. It is effectively a per-user global default.
- `profile/phpvm-hook.ps1` overrides `prompt` and calls `phpvm --auto --quiet` on every directory change, which calls `Set-PhpvmActive`, which **rewrites the global shim**. So changing directory in one terminal silently repoints PHP in all terminals. This is exactly the problem Linux fixed in v2.5.0.

### 4.2 Target model (matches Linux v2.5.0+)

Three resolution layers, highest priority first, resolved by the shim at call time:

1. **shell**: `%PHPVM_SHELL_VERSION%` (set by `phpvm shell`, lives only in the current PowerShell session)
2. **project**: `%PHPVM_AUTO_VERSION%` (set by the `cd`-hook from `.php-version` / `composer.json`)
3. **global**: the persisted default (the current `.active` meta, or a `default` pointer)

To make this resolvable by a `.cmd` shim quickly (no spawning PowerShell per `php` call), introduce **per-version junctions**, the Windows analog of Linux's `/usr/bin/phpX.Y`:

```
%USERPROFILE%\.phpvm\versions\8.1  ->  (junction to the real 8.1 install dir)
%USERPROFILE%\.phpvm\versions\8.2  ->  (junction to the real 8.2 install dir)
%USERPROFILE%\.phpvm\versions\8.3  ->  (junction to the real 8.3 install dir)
```

Directory junctions (`New-Item -ItemType Junction`, or `mklink /J`) do **not** require admin rights, unlike symlinks. They are created during a scan/switch for every discovered install.

The shim `php.cmd` becomes a resolver that reads the three env vars and dispatches to `versions\<minor>\php.exe`:

```bat
@echo off
setlocal
set "PHPVM_ROOT=%USERPROFILE%\.phpvm"
set "VER=%PHPVM_SHELL_VERSION%"
if not defined VER set "VER=%PHPVM_AUTO_VERSION%"
if not defined VER for /f "usebackq tokens=2 delims==" %%v in (`findstr /b "minor=" "%PHPVM_ROOT%\shim\.active"`) do set "VER=%%v"
if not defined VER (
  echo phpvm: no active PHP. Run 'phpvm global ^<ver^>'. 1>&2
  exit /b 1
)
set "TARGET=%PHPVM_ROOT%\versions\%VER%\php.exe"
if not exist "%TARGET%" (
  echo phpvm: PHP %VER% is not registered. Run 'phpvm --list'. 1>&2
  exit /b 1
)
endlocal & "%PHPVM_ROOT%\versions\%VER%\php.exe" %*
```

(The exact `findstr`/`for` parsing can be tightened; the point is the shim does the layered lookup with no PowerShell process.)

### 4.3 The wrapper function problem

On Linux, `phpvm shell` cannot set the parent shell's env from a subprocess, so phpvm ships a `phpvm()` shell function that intercepts `shell` and the TUI and routes them through `eval`. **The same constraint applies on Windows.** The `phpvm.cmd`/`phpvm.ps1` runs in a separate `powershell` process, so it cannot mutate the caller's session env either.

Solution: the profile gains a `function phpvm` wrapper (installed by `Enable-Hook`, alongside the `cd`-hook), for example:

```powershell
function global:phpvm {
    if ($args.Count -ge 1 -and $args[0] -eq 'shell') {
        # handled in-session so $env:PHPVM_SHELL_VERSION sticks in THIS terminal
        if ($args.Count -ge 2 -and $args[1] -eq '--unset') {
            Remove-Item Env:PHPVM_SHELL_VERSION -ErrorAction SilentlyContinue
            Write-Host 'phpvm: shell pin removed for this terminal.'
            return
        }
        $ver = & (Join-Path $env:USERPROFILE '.phpvm\bin\phpvm.ps1') 'sh-shell' $args[1]
        if ($LASTEXITCODE -eq 0 -and $ver) {
            $env:PHPVM_SHELL_VERSION = $ver
            Write-Host "phpvm: pinned this terminal to PHP $ver."
        }
        return
    }
    & (Join-Path $env:USERPROFILE '.phpvm\bin\phpvm.ps1') @args
}
```

Add a hidden `sh-shell <ver>` subcommand to `phpvm.ps1` (mirrors Linux `sh-shell`): it validates the version against installed versions, prints the normalized minor on stdout for the wrapper to capture, and exits non-zero with a message if not installed. The bare `phpvm` (TUI) Enter-to-pin path also routes through the wrapper so it can set `$env:PHPVM_SHELL_VERSION` in-session, the way Linux does.

### 4.4 The hook change

Rewrite `profile/phpvm-hook.ps1` so the prompt override sets the **project env var** instead of switching the global shim:

```powershell
function global:prompt {
    if ($PWD.Path -ne $global:__PhpvmLastDir) {
        $global:__PhpvmLastDir = $PWD.Path
        try {
            $v = & phpvm --auto --print 2>$null
            if ($v) { $env:PHPVM_AUTO_VERSION = "$v".Trim() }
            else    { Remove-Item Env:PHPVM_AUTO_VERSION -ErrorAction SilentlyContinue }
        } catch { }
    }
    if ($global:__PhpvmOriginalPrompt) { & $global:__PhpvmOriginalPrompt } else { "PS $($PWD.Path)> " }
}
```

This makes `cd` per-terminal and never touches the global default. A shell pin (`PHPVM_SHELL_VERSION`) always wins over the project var because the shim checks it first.

### 4.5 Verb rename

- `--set <ver>` becomes `phpvm global <ver>` (rewrites `.active` / the default). Keep `--set` and `-s` as aliases.
- `--set-project <ver>` becomes `phpvm local <ver>` (writes `.php-version`). Keep `--set-project` and `-p` as aliases.
- Add `phpvm shell <ver>` and `phpvm shell --unset` (handled by the wrapper, see 4.3).

### 4.6 `--current` layers

Rewrite `Show-Current` to print the effective version plus the three layers, reading `$env:PHPVM_SHELL_VERSION`, `$env:PHPVM_AUTO_VERSION` (or resolving the project from cwd when the hook has not run), and the persisted default, the way Linux `cmd_current` does. Add the inactive-shim hint when a pin is set but `Get-Command php` does not resolve to the shim.

### 4.7 Self-heal ordering (port of v2.5.1 / v2.6.1)

Windows has the same class of problem: another tool can prepend a `php.exe` ahead of the shim dir on `PATH`. Add a small `_phpvm_path_fix`-equivalent the prompt hook calls each time: ensure `%USERPROFILE%\.phpvm\shim` sits ahead of any other directory containing `php.exe` in the **process** `PATH` (`$env:Path`), re-asserting on each prompt. Keep it a no-op when already in front.

---

## 5. Phased rollout

### Phase 0 - Housekeeping (ship as 1.0.1)

Pure fixes, no new features. These are real bugs.

- `install.ps1` line ~40: default repo is the placeholder `https://github.com/OWNER/phpvm-windows`. Change to `https://github.com/rijverse/phpvm-win`.
- `CHANGELOG.md` compare/tag links: `OWNER/phpvm-windows` -> `rijverse/phpvm-win`.
- `README.md`: every `rijoanul-shanto/phpvm-win` and the sister link `rijoanul-shanto/phpvm` -> `rijverse/phpvm-win` and `rijverse/phpvm`. CI badge URL too.
- `README.md` "Comparison to Linux phpvm" table says "CLI surface | Identical". It is not anymore. Either soften now or update it at the end of Phase 2.

### Phase 1 - IDE primitives (1.1.0)

Low effort, high value, no architecture change.

- `phpvm which <ver>`: resolve via `Find-PhpInstallByQuery` and print `.Path` (bare, stdout only). Accept `8.2` and `php8.2`.
- `phpvm --list --paths`: add an absolute-path column to `Show-VersionList`, keep the active marker.
- `phpvm --list --json`: emit `[{"version","path","active"}, ...]`. Build it by hand or with `ConvertTo-Json` (force an array with `,@(...)`), one entry per install.
- `docs/IDE.md`: PhpStorm (CLI Interpreter), VS Code (`php.validate.executablePath`, `intelephense.environment.phpVersion`), with Windows paths. Mirror the Linux `docs/IDE.md`.
- Tests: Pester cases for `which` (hit/miss), `--list --json` shape (valid JSON, correct active flag).

### Phase 2 - Per-shell switching (1.2.0) [headline]

Implement section 4 in full:

- `lib/switch.ps1`: add per-version junction creation (`Register-PhpvmVersions`), rewrite the shim to the resolver form, add `Set-PhpvmGlobal` (persist default), keep `Set-PhpvmActive` semantics for the default pointer.
- `phpvm.ps1`: add `shell` / `sh-shell` dispatch, rename `--set`/`--set-project` to `global`/`local` with aliases, rewrite `Show-Current` for layers.
- `profile/phpvm-hook.ps1`: prompt sets `PHPVM_AUTO_VERSION`, add the `phpvm` wrapper function and the path-fix.
- `Enable-Hook`: install both the prompt hook and the wrapper function into the profile.
- `lib/doctor.ps1`: add a "Per-shell switching" section (shim present, shim dir on `PATH`, junctions present, current layer state).
- Update the README "Comparison" table and add a "Per-shell switching" section mirroring the Linux one.
- Tests: two-session simulation (set `PHPVM_SHELL_VERSION` in one, assert the shim resolves it without affecting the default), hook sets `PHPVM_AUTO_VERSION` and not the global default, shell pin beats project var.

This phase changes `cd` behavior (no longer a global switch). Consider whether to call it 2.0.0 instead of 1.2.0 since the hook semantics change; recommended to stay 1.x because the user-facing improvement is strictly better and the flag surface is backward compatible (old flags remain as aliases).

### Phase 3 - `phpvm install <ver>` (1.3.0)

Windows PHP acquisition. Design decision required; recommended approach:

- **Primary: direct download from windows.php.net.** Fetch the NTS x64 zip for the requested minor from `https://windows.php.net/downloads/releases/` (current) or `/archives/` (older), verify the published SHA256, extract to `%USERPROFILE%\.phpvm\php\<minor>`, then register a junction `versions\<minor> -> php\<minor>`. This is the closest analog to Linux installing from the upstream repo, and it is fully self-contained.
  - Pick NTS (non-thread-safe) x64 by default; that is the right build for CLI and the shim. TS is only needed for Apache mod_php, which is out of scope.
  - `--print` dry-run: show the resolved URL and target dir, touch nothing (CI-safe).
  - `latest`: scrape the releases index for the highest `X.Y`.
- **Fast path: Scoop.** If Scoop is present and has a matching `php` bucket app, offer `scoop install` instead (detected, never required).
- Reject patch-level args (`8.2.13`) like Linux does.
- Tests: `--print` output shape against a stubbed index, idempotency when the minor already exists.

### Phase 4 - GUI / tray (2.0.0) [optional, larger]

Currently `--window` is a stub. Two viable Windows paths:

- **Dependency-free: PowerShell + WinForms `NotifyIcon`.** `System.Windows.Forms.NotifyIcon` gives a tray icon and context menu with no extra install (works in Windows PowerShell 5.1 on .NET Framework, and in PowerShell 7 on Windows via the Desktop runtime). A hidden form runs the message loop. Menu lists installed versions, click switches the global default, a refresh timer updates the checkmark.
- **Robust: a small compiled .NET (C#) tray app** shipped as `phpvm-gui.exe`. More work, but a cleaner long-lived process and easier packaging.

Mirror what makes sense from the Linux GUI: per-version rows, active marker, xdebug presence, and a switch action. SAPI/FPM badges are largely Linux-specific and can be dropped. Recommended to keep this as its own milestone and not block parity on it.

### Phase 5 - Polish parity (folded into the phase that touches each area)

- Confirmation lines on `shell` / `shell --unset` (done via the wrapper in Phase 2).
- Inactive-shim hint in `--current` and after `shell` when the shim is shadowed on `PATH`.
- A single `Get-ShimStatus` helper (`active` / `shadowed` / `absent` / `noshim`) shared by `shell`, `--current`, and `--doctor`, mirroring Linux's `shim_status`.

---

## 6. Files to touch (quick index)

| File | Phase(s) | Change |
| --- | --- | --- |
| `install.ps1` | 0 | Fix placeholder repo URL |
| `CHANGELOG.md` | 0, every | Fix links; add entries per release |
| `README.md` | 0, 1, 2 | Fix org links; commands table; comparison table; per-shell + IDE sections |
| `phpvm.ps1` | 1, 2, 3 | `which`, list flags, `shell`/`sh-shell`, `local`/`global`, `install`, `--current` rewrite |
| `lib/switch.ps1` | 2 | Junctions, resolver shim, global vs shell vs default |
| `lib/detect.ps1` | 1, 2 | Path column data, junction-aware active detection |
| `lib/doctor.ps1` | 2, 5 | Per-shell section, shim status helper |
| `profile/phpvm-hook.ps1` | 2 | Set `PHPVM_AUTO_VERSION`, wrapper function, path-fix |
| `lib/install-php.ps1` (new) | 3 | windows.php.net downloader + Scoop fast path |
| `lib/gui.ps1` or `phpvm-gui.ps1` (new) | 4 | Tray app |
| `docs/IDE.md` (new) | 1 | PhpStorm / VS Code on Windows |
| `tests/Pester.Tests.ps1` | every | New cases per feature |

---

## 7. Windows-specific gotchas (do not get surprised)

- **Env var inheritance.** `$env:X = '...'` in a session is inherited by child processes (the `.cmd` shim reads it). That is what makes per-shell work. But a child cannot set the parent's env, hence the profile wrapper function is mandatory (section 4.3), exactly like Linux's `eval`.
- **Junctions vs symlinks.** Use junctions (`New-Item -ItemType Junction`). They need no admin and no Developer Mode. Symlinks need elevation.
- **Shim speed.** Do not spawn PowerShell inside the shim resolver. Keep it pure `.cmd` plus a junction lookup, or `php` startup latency becomes painful.
- **`PHPRC` hijack.** A stray `PHPRC` can point php at the wrong ini. Doctor should flag it (the README already mentions this).
- **AV quarantine of `.cmd`.** Already documented; keep the AV-exclusion note.
- **User PATH length.** `install.ps1` already warns past 2048 chars. The new `versions\` dir is not added to PATH (only `shim` and `bin` are), so this does not get worse.
- **Constrained Language Mode** blocks install; already guarded.
- **Profile split.** PS 5.1 and PS 7 use different `$PROFILE` paths. `Enable-Hook` already writes both `CurrentUserAllHosts` targets; make sure the new wrapper function lands in the same place.

---

## 8. Versioning and changelog

Proposed releases:

- **1.0.1** - Phase 0 (branding/URL fixes).
- **1.1.0** - Phase 1 (`which`, list paths/json, IDE docs).
- **1.2.0** - Phase 2 (per-shell switching, `local`/`global`, `--current` layers, self-heal). The big one.
- **1.3.0** - Phase 3 (`install`).
- **2.0.0** - Phase 4 (GUI/tray), if and when it ships.

Keep `phpvm-win` on its own SemVer line. Do not mirror Linux numbers. Each phase adds a `## [x.y.z]` block to `CHANGELOG.md` and updates the `[Unreleased]` compare link (which today still points at the placeholder `OWNER/phpvm-windows`, fix in Phase 0).

---

## 9. Suggested order of work

1. Phase 0 in one small PR (fixes shipped bugs immediately).
2. Phase 1 next (self-contained, unlocks IDE users, no risk to the switch path).
3. Phase 2 as its own focused effort (the architecture change, most testing).
4. Phase 3 and Phase 4 independently, in either order, once parity on switching exists.

Phases 1 through 3 get phpvm-win to functional parity with everything Linux phpvm does on the command line. Phase 4 (GUI) is the only piece that is genuinely a new sub-project rather than a port.
