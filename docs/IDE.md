# Using phpvm with your IDE on Windows

phpvm swaps PHP behind a `.cmd` shim on `PATH`. Most IDEs ignore that shim - they
want a concrete `php.exe`, or they read the version once and cache it. So you
have to hand them a path yourself.

Two commands give you that path:

```powershell
phpvm which 8.2        # absolute php.exe path for a version
phpvm --list --paths   # every install with its php.exe path
phpvm --list --json    # machine-readable [{version, path, active}]
```

`phpvm which <ver>` prints just the path, nothing else, so it drops straight into
a script:

```powershell
$php = phpvm which 8.2
& $php -v
```

## PhpStorm

PhpStorm pins a "CLI Interpreter" per project; it does not follow the shim.

1. `File > Settings > PHP`.
2. Next to **CLI Interpreter**, click `...`.
3. Add a **Local** interpreter and set the **PHP executable** to the output of
   `phpvm which <ver>`, for example:

   ```
   C:\Users\you\scoop\apps\php\current\php.exe
   ```

4. Repeat per project if different projects pin different versions
   (`.php-version` / `composer.json`).

To point PhpStorm at the active version, run `phpvm --current` (or
`phpvm which <minor>`) and paste the path. PhpStorm re-reads the binary's
version, so you do not have to set it by hand.

## VS Code

VS Code itself has no PHP interpreter setting; the PHP extensions do. Set these
in the workspace `.vscode/settings.json` so each project can differ.

### Built-in PHP language features

```json
{
  "php.validate.executablePath": "C:\\Users\\you\\scoop\\apps\\php\\current\\php.exe"
}
```

Get the exact path with `phpvm which 8.2`.

### Intelephense

```json
{
  "intelephense.environment.phpVersion": "8.2.0"
}
```

`intelephense.environment.phpVersion` takes a version string, not a path. Read
it from `phpvm --list --json` and pick the entry where `active` is `true`.

### PHP Debug (Xdebug)

The debug adapter launches `php` from `PATH`, so it follows the phpvm shim with
no extra config, as long as `%USERPROFILE%\.phpvm\shim` is ahead of any other
PHP on `PATH`. Verify with:

```powershell
phpvm --doctor
```

## Generating settings from phpvm

To wire the active interpreter into a workspace without copy-paste:

```powershell
$php = phpvm which 8.2
$settings = @{ 'php.validate.executablePath' = $php } | ConvertTo-Json
New-Item -ItemType Directory -Force .vscode | Out-Null
Set-Content -LiteralPath .vscode\settings.json -Value $settings -Encoding UTF8
```

## Why the IDE doesn't just follow the shim

The shim is a `.cmd`, and it picks the version at call time. IDEs launch
`php.exe` directly, not through `cmd.exe`, and most read the version once on
startup. Give them a real path and the editor and the CLI stay in sync.
