# Sourced by interactive zsh and bash: keep to code both shells understand.

# Creates a directory and moves into it.
mkcd() {
  mkdir -p -- "$1" && cd -- "$1" || return
}
