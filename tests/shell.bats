#!/usr/bin/env bats
# Startup files, without mise.

load helper

setup() {
  sandbox_setup
  load_libs
  FILE=$HOME/.bashrc
  CONTENT=$'# stock\ncase $- in *i*) ;; *) return ;; esac\nalias ll="ls -l"\n'
}

@test "a missing file is created with the block alone" {
  shell_block_apply "$FILE"
  [ "$(head -n 1 "$FILE")" = '# >>> povy >>>' ]
  [ "$(tail -n 1 "$FILE")" = '# <<< povy <<<' ]
}

@test "the block goes above the existing content, which stays byte for byte" {
  printf '%s' "$CONTENT" >"$FILE"
  shell_block_apply "$FILE"
  [ "$(head -n 1 "$FILE")" = '# >>> povy >>>' ]
  [ "$(sed '1,/^# <<< povy <<<$/d' "$FILE")" = "$(printf '%s' "$CONTENT")" ]
}

@test "content with no final newline is kept as it is" {
  printf 'no newline' >"$FILE"
  shell_block_apply "$FILE"
  [ "$(tail -c 10 "$FILE")" = 'no newline' ]
}

@test "a second run changes nothing and makes no backup" {
  printf '%s' "$CONTENT" >"$FILE"
  shell_block_apply "$FILE"
  cp "$FILE" "$FILE.first"
  POVY_BACKUP_DIR=""
  POVY_BACKED_UP=0
  shell_block_apply "$FILE"
  cmp "$FILE" "$FILE.first"
  [ "$POVY_BACKED_UP" -eq 0 ]
}

@test "a file the run created is not backed up when its second block goes in" {
  shell_block_apply "$FILE"
  shell_block_apply "$FILE" interactive bottom interactive
  grep -qxF '# >>> povy interactive >>>' "$FILE"
  [ "$POVY_BACKED_UP" -eq 0 ]
  [ ! -e "$POVY_BACKUP_DIR/.bashrc" ]
}

@test "the original is backed up before the first change" {
  printf '%s' "$CONTENT" >"$FILE"
  shell_block_apply "$FILE"
  [ "$(cat "$POVY_BACKUP_DIR/.bashrc")" = "$(printf '%s' "$CONTENT")" ]
}

@test "a stale block is refreshed in place, without moving" {
  printf 'before\n# >>> povy >>>\nold\n# <<< povy <<<\nafter\n' >"$FILE"
  shell_block_apply "$FILE"
  [ "$(head -n 1 "$FILE")" = before ]
  [ "$(tail -n 1 "$FILE")" = after ]
  ! grep -qxF old "$FILE"
  [ "$(grep -cxF '# >>> povy >>>' "$FILE")" -eq 1 ]
}

@test "an incomplete block is refused, the file is not touched" {
  printf 'keep\n# >>> povy >>>\nmore\n' >"$FILE"
  cp "$FILE" "$FILE.orig"
  run shell_block_apply "$FILE"
  [ "$status" -ne 0 ]
  cmp "$FILE" "$FILE.orig"
}

@test "a symlinked dotfile stays a symlink and its target gets the block" {
  mkdir "$HOME/dotfiles"
  printf 'mine\n' >"$HOME/dotfiles/bashrc"
  ln -s "$HOME/dotfiles/bashrc" "$FILE"
  shell_block_apply "$FILE"
  [ -L "$FILE" ]
  grep -qxF '# >>> povy >>>' "$HOME/dotfiles/bashrc"
  [ ! -L "$POVY_BACKUP_DIR/.bashrc" ]
  grep -qxF mine "$POVY_BACKUP_DIR/.bashrc"
}

@test "the file mode is preserved" {
  printf 'x\n' >"$FILE"
  chmod 640 "$FILE"
  shell_block_apply "$FILE"
  [ "$(file_mode "$FILE")" = 640 ]
}

@test "an existing .profile is used rather than hidden by a new .bash_profile" {
  touch "$HOME/.profile"
  [ "$(shell_bash_login_file)" = "$HOME/.profile" ]
  touch "$HOME/.bash_login"
  [ "$(shell_bash_login_file)" = "$HOME/.bash_login" ]
  touch "$HOME/.bash_profile"
  [ "$(shell_bash_login_file)" = "$HOME/.bash_profile" ]
}

@test "ZDOTDIR is honoured" {
  export ZDOTDIR=$HOME/zdot
  run shell_startup_files
  if command -v zsh >/dev/null; then
    [[ "$output" == *"$HOME/zdot/.zshenv"* ]]
  fi
  [[ "$output" != *"$HOME/.zshenv"* ]]
}

@test "paths are written with \$HOME, and other paths are quoted safely" {
  [ "$(shell_path_literal "$HOME/.config/x")" = '"$HOME/.config/x"' ]
  [ "$(shell_path_literal "/opt/it's here")" = "'/opt/it'\\''s here'" ]
}

env_sh_path() {
  local shell_cmd=$1 start=$2
  env -i HOME="$HOME" PATH="$start" /bin/sh -c "command -v $shell_cmd >/dev/null" 2>/dev/null
  env -i HOME="$HOME" PATH="$start" "$(command -v "$shell_cmd")" -c ". \"$POVY_ENV_SH\"; printf '%s' \"\$PATH\""
}

@test "env.sh moves the shims to the front, without duplicates, in every shell" {
  local shell_cmd s="$POVY_SHIMS_DIR" b="$POVY_LOCAL_BIN"
  shell_write_env
  for shell_cmd in sh bash zsh dash; do
    command -v "$shell_cmd" >/dev/null || continue
    [ "$(env_sh_path "$shell_cmd" /usr/bin:/bin)" = "$s:$b:/usr/bin:/bin" ]
    [ "$(env_sh_path "$shell_cmd" "/usr/bin:$s:/bin:$b")" = "$s:$b:/usr/bin:/bin" ]
    [ "$(env_sh_path "$shell_cmd" "$s:$b:/usr/bin")" = "$s:$b:/usr/bin" ]
  done
}

@test "env.sh leaves no helper behind" {
  shell_write_env
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c ". \"$POVY_ENV_SH\"; declare -F __povy_path_front; echo \"[\${__povy_p:-}]\""
  [ "$output" = '[]' ]
}

@test "only the files that interactive shells read load the banner" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  shell_apply_blocks
  grep -qF '.config/povy/env.sh' "$HOME/.zshenv"
  ! grep -qF 'interactive.sh' "$HOME/.zshenv"
  ! grep -qF 'interactive.sh' "$HOME/.zprofile"
  grep -qF '.config/povy/interactive.sh' "$HOME/.zshrc"
  ! grep -qF 'env.sh' "$HOME/.zshrc"
  grep -qF 'env.sh' "$HOME/.bashrc"
  grep -qF 'interactive.sh' "$HOME/.bashrc"
}

@test "a login file gets the block at the end, after what it adds to PATH" {
  printf 'eval "$(brew shellenv)"\n' >"$HOME/.zprofile"
  shell_block_apply "$HOME/.zprofile" env bottom
  [ "$(head -n 1 "$HOME/.zprofile")" = 'eval "$(brew shellenv)"' ]
  [ "$(tail -n 1 "$HOME/.zprofile")" = '# <<< povy <<<' ]
}

@test "a block at the top of a login file moves to the end, the rest stays" {
  printf 'export A=1\n# end of mine' >"$HOME/.zprofile"
  shell_block_apply "$HOME/.zprofile" env top
  shell_block_apply "$HOME/.zprofile" env bottom
  [ "$(sed -n 1p "$HOME/.zprofile")" = 'export A=1' ]
  [ "$(sed -n 2p "$HOME/.zprofile")" = '# end of mine' ]
  [ "$(sed -n 3p "$HOME/.zprofile")" = '# >>> povy >>>' ]
  [ "$(grep -c '# >>> povy >>>' "$HOME/.zprofile")" -eq 1 ]
  [ -n "$(find "$HOME/.local/state/povy/backups" -name .zprofile)" ]
}

@test "a block already at the end is left alone, with no backup" {
  printf 'export A=1\n' >"$HOME/.zprofile"
  shell_block_apply "$HOME/.zprofile" env bottom
  POVY_WRITTEN=0
  POVY_BACKED_UP=0
  shell_block_apply "$HOME/.zprofile" env bottom
  [ "$POVY_WRITTEN" -eq 0 ]
  [ "$POVY_BACKED_UP" -eq 0 ]
}

@test "in a login zsh, the shims come before what .zprofile prepends" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  mkdir -p "$HOME/fakebin"
  printf 'export PATH="$HOME/fakebin:$PATH"\n' >"$HOME/.zprofile"
  shell_write_env
  shell_apply_blocks
  run env -i HOME="$HOME" PATH=/usr/bin:/bin zsh -lc 'printf "%s" "$PATH"'
  [[ "$output" == "$POVY_SHIMS_DIR:"* ]]
}
