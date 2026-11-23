# Sourced by interactive PowerShell on Windows, like aliases.sh in zsh and bash.

function ll { Get-ChildItem -Force @args }

# Creates a directory and moves into it.
function mkcd([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-Location -LiteralPath $Path
}
