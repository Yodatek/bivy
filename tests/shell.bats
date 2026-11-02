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
  [ "$(head -n 1 "$FILE")" = '# >>> bivy >>>' ]
  [ "$(tail -n 1 "$FILE")" = '# <<< bivy <<<' ]
}

@test "the block goes above the existing content, which stays byte for byte" {
  printf '%s' "$CONTENT" >"$FILE"
  shell_block_apply "$FILE"
  [ "$(head -n 1 "$FILE")" = '# >>> bivy >>>' ]
  [ "$(sed '1,/^# <<< bivy <<<$/d' "$FILE")" = "$(printf '%s' "$CONTENT")" ]
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
  BIVY_BACKUP_DIR=""
  BIVY_BACKED_UP=0
  shell_block_apply "$FILE"
  cmp "$FILE" "$FILE.first"
  [ "$BIVY_BACKED_UP" -eq 0 ]
}

@test "the original is backed up before the first change" {
  printf '%s' "$CONTENT" >"$FILE"
  shell_block_apply "$FILE"
  [ "$(cat "$BIVY_BACKUP_DIR/.bashrc")" = "$(printf '%s' "$CONTENT")" ]
}

@test "a stale block is refreshed in place, without moving" {
  printf 'before\n# >>> bivy >>>\nold\n# <<< bivy <<<\nafter\n' >"$FILE"
  shell_block_apply "$FILE"
  [ "$(head -n 1 "$FILE")" = before ]
  [ "$(tail -n 1 "$FILE")" = after ]
  ! grep -qxF old "$FILE"
  [ "$(grep -cxF '# >>> bivy >>>' "$FILE")" -eq 1 ]
}

@test "an incomplete block is refused, the file is not touched" {
  printf 'keep\n# >>> bivy >>>\nmore\n' >"$FILE"
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
  grep -qxF '# >>> bivy >>>' "$HOME/dotfiles/bashrc"
  [ ! -L "$BIVY_BACKUP_DIR/.bashrc" ]
  grep -qxF mine "$BIVY_BACKUP_DIR/.bashrc"
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
  env -i HOME="$HOME" PATH="$start" "$(command -v "$shell_cmd")" -c ". \"$BIVY_ENV_SH\"; printf '%s' \"\$PATH\""
}

@test "env.sh moves the shims to the front, without duplicates, in every shell" {
  local shell_cmd s="$BIVY_SHIMS_DIR" b="$BIVY_LOCAL_BIN"
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
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c ". \"$BIVY_ENV_SH\"; declare -F __bivy_path_front; echo \"[\${__bivy_p:-}]\""
  [ "$output" = '[]' ]
}
