# phpvm auto-switch hook
# Override `prompt` so cd-into-project triggers `phpvm --auto`.
# Idempotent — safe to dot-source twice; only the first run wraps the prompt.

if ($global:__PhpvmHookInstalled) { return }
$global:__PhpvmHookInstalled = $true
$global:__PhpvmLastDir = $null

$global:__PhpvmOriginalPrompt = $function:prompt

function global:prompt {
    if ($PWD.Path -ne $global:__PhpvmLastDir) {
        $global:__PhpvmLastDir = $PWD.Path
        try {
            & phpvm --auto --quiet 2>$null | Out-Null
        } catch {
            # swallow — hook must never break the prompt
        }
    }
    if ($global:__PhpvmOriginalPrompt) {
        & $global:__PhpvmOriginalPrompt
    } else {
        "PS $($PWD.Path)> "
    }
}
