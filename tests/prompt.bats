#!/usr/bin/env bats
# The prompt key and where the startup blocks go. A fake starship stands in for the
# real one, so nothing is installed.

load helper

setup() {
  sandbox_setup
  load_libs
  FAKE=$BATS_TEST_TMPDIR/bin/starship
  mkdir -p "${FAKE%/*}"
  cat >"$FAKE" <<'SH'
#!/bin/sh
case "$1 $2" in
  "init zsh") echo "PROMPT='starship> '" ;;
  "init bash") echo "PS1='starship> '" ;;
esac
SH
  chmod +x "$FAKE"
  prompt_starship_path() { printf '%s\n' "$FAKE"; }
  CFG_BANNER=false
  CFG_PROMPT=starship
}

# Writes what apply writes for the shells.
apply_shell() {
  shell_write_env
  shell_write_interactive
  shell_apply_blocks
}

@test "a zsh started after a framework that sets the prompt gets starship" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  printf "PROMPT='omz> '\n" >"$HOME/.zshrc"
  apply_shell
  [ "$(tail -n 1 "$HOME/.zshrc")" = '# <<< bivy <<<' ]
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=xterm zsh -i -c 'print -r -- "$PROMPT"'
  [ "${lines[${#lines[@]} - 1]}" = 'starship> ' ]
}

@test "a bash whose .bashrc sets PS1 gets starship" {
  printf "PS1='debian> '\n" >"$HOME/.bashrc"
  apply_shell
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=xterm bash -i -c 'printf "%s\n" "$PS1"'
  [ "${lines[${#lines[@]} - 1]}" = 'starship> ' ]
}

@test "a dumb terminal keeps its prompt" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  printf "PROMPT='omz> '\n" >"$HOME/.zshrc"
  apply_shell
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb zsh -i -c 'print -r -- "$PROMPT"'
  [ "${lines[${#lines[@]} - 1]}" = 'omz> ' ]
}

@test "without a prompt choice, interactive.sh sets none" {
  CFG_PROMPT=""
  apply_shell
  ! grep -q starship "$HOME/.config/bivy/interactive.sh"
}

@test ".bashrc keeps env at the top and gets a named interactive block at the bottom" {
  printf 'case $- in *i*) ;; *) return ;; esac\nalias ll="ls -l"\n' >"$HOME/.bashrc"
  apply_shell
  [ "$(head -n 1 "$HOME/.bashrc")" = '# >>> bivy >>>' ]
  [ "$(tail -n 1 "$HOME/.bashrc")" = '# <<< bivy interactive <<<' ]
  [ "$(awk '/^# <<< bivy <<<$/ { exit } { print }' "$HOME/.bashrc" | grep -c interactive.sh)" -eq 0 ]
}

@test "the earlier layout moves: .zshrc to the end, .bashrc split in two" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  printf 'export MINE=1\n' >"$HOME/.zshrc"
  printf 'export MINE=1\n' >"$HOME/.bashrc"
  shell_block_apply "$HOME/.zshrc" interactive top
  shell_block_apply "$HOME/.bashrc" "env interactive" top
  apply_shell
  [ "$(head -n 1 "$HOME/.zshrc")" = 'export MINE=1' ]
  [ "$(tail -n 1 "$HOME/.zshrc")" = '# <<< bivy <<<' ]
  [ "$(grep -c '^# >>> bivy' "$HOME/.zshrc")" -eq 1 ]
  [ "$(head -n 1 "$HOME/.bashrc")" = '# >>> bivy >>>' ]
  [ "$(tail -n 1 "$HOME/.bashrc")" = '# <<< bivy interactive <<<' ]
  [ "$(grep -c 'interactive.sh' "$HOME/.bashrc")" -eq 1 ]
  grep -qxF 'export MINE=1' "$HOME/.bashrc"
}

@test "starship joins the tools only when a prompt asks for it, and the machine wins" {
  PROFILE_PROMPT=starship
  CFG_PROMPT=""
  [[ "$(tools_merged)" == *$'starship\t1.27.0\tbivy'* ]]
  CFG_PROMPT=none
  [[ "$(tools_merged)" != *starship* ]]
}

@test "prompt must be starship or none" {
  write_config "$BATS_TEST_TMPDIR/c.toml"
  printf 'prompt = "fancy"\n' >>"$BATS_TEST_TMPDIR/c.toml"
  run bivy init --config "$BATS_TEST_TMPDIR/c.toml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"prompt must be starship or none"* ]]
}
