# Sourced by interactive PowerShell on Windows, like functions.sh and the aliases of
# team.toml in zsh and bash.

function ll { Get-ChildItem -Force @args }

# Creates a directory and moves into it.
function mkcd([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-Location -LiteralPath $Path
}

# The prompt, as on the other systems.
if (Get-Command starship -ErrorAction Ignore) {
    Invoke-Expression (& starship init powershell --print-full-init | Out-String)
}
