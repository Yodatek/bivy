#!/usr/bin/env bats
# Startup files, without mise.

load helper

setup() {
  sandbox_setup
  load_libs
  FILE=$HOME/.bashrc
  CONTENT=$'# stock\ncase $- in *i*) ;; *) return ;; esac\nalias ll="ls -l"\n'
}

# Writes what apply writes for the shells.
apply_shell() {
  shell_write_env
  shell_write_interactive
  shell_apply_blocks
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
  [ "$(file_mode "$POVY_BACKUP_DIR/.bashrc")" = 600 ]
}

@test "a stale block is refreshed in place, without moving" {
  printf 'before\n# >>> povy >>>\nold\n# <<< povy <<<\nafter\n' >"$FILE"
  shell_block_apply "$FILE"
  [ "$(head -n 1 "$FILE")" = before ]
  [ "$(tail -n 1 "$FILE")" = after ]
  ! grep -qxF old "$FILE" || false
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

@test "with ZDOTDIR, env goes in ~/.zshenv and in \$ZDOTDIR/.zshenv, the other zsh files in ZDOTDIR" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  local files=$BATS_TEST_TMPDIR/files
  export ZDOTDIR=$HOME/zdot
  shell_startup_files >"$files"
  grep -qxF "$HOME/.zshenv"$'\tenv\ttop\t' "$files"
  grep -qxF "$ZDOTDIR/.zshenv"$'\tenv\ttop\t' "$files"
  grep -qxF "$ZDOTDIR/.zprofile"$'\tenv\tbottom\t' "$files"
  grep -qxF "$ZDOTDIR/.zshrc"$'\tinteractive\tbottom\t' "$files"
  ! grep -qF "$HOME/.zprofile" "$files" || false
  ! grep -qF "$HOME/.zshrc" "$files" || false
  # A ZDOTDIR that is HOME gives one .zshenv.
  [ "$(ZDOTDIR=$HOME shell_startup_files | grep -c '/\.zshenv')" -eq 1 ]
}

@test "with ZDOTDIR, zsh has the shims first whether ZDOTDIR is set when it starts or not" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  local start
  export ZDOTDIR=$HOME/zdot
  mkdir -p "$ZDOTDIR"
  # The usual setup: ~/.zshenv moves the other files to ZDOTDIR.
  printf 'export ZDOTDIR="$HOME/zdot"\n' >"$HOME/.zshenv"
  apply_shell
  grep -qF '.config/povy/env.sh' "$HOME/.zshenv"
  grep -qF '.config/povy/env.sh' "$ZDOTDIR/.zshenv"
  [ "$(tail -n 1 "$HOME/.zshenv")" = 'export ZDOTDIR="$HOME/zdot"' ]
  for start in "ZDOTDIR=$ZDOTDIR zsh -c" "ZDOTDIR=$ZDOTDIR zsh -lc" "zsh -c" "zsh -lc"; do
    # shellcheck disable=SC2086 # The variables and the shell to start.
    run env -i HOME="$HOME" PATH=/usr/bin:/bin $start 'printf "%s" "$PATH"'
    [[ "$output" == "$POVY_SHIMS_DIR:"* ]] || {
      echo "no shims first with $start: $output"
      return 1
    }
  done
}

@test "paths are written with \$HOME, and other paths are quoted safely" {
  [ "$(shell_path_literal "$HOME/.config/x")" = '"$HOME/.config/x"' ]
  [ "$(shell_path_literal "/opt/it's here")" = "'/opt/it'\\''s here'" ]
}

env_sh_path() {
  local shell_cmd=$1 start=$2
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

@test "env.sh puts the profile's commands between the shims and ~/.local/bin" {
  local shell_cmd s="$POVY_SHIMS_DIR" p="$HOME/.local/state/povy/profile/bin" b="$POVY_LOCAL_BIN"
  POVY_BINS=$p
  shell_write_env
  grep -qxF '__povy_path_front "$HOME/.local/state/povy/profile/bin"' "$POVY_ENV_SH"
  for shell_cmd in sh bash zsh dash; do
    command -v "$shell_cmd" >/dev/null || continue
    [ "$(env_sh_path "$shell_cmd" /usr/bin:/bin)" = "$s:$p:$b:/usr/bin:/bin" ]
    [ "$(env_sh_path "$shell_cmd" "$b:/usr/bin:$p:$s")" = "$s:$p:$b:/usr/bin" ]
  done
}

@test "env.sh leaves no helper behind" {
  shell_write_env
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c ". \"$POVY_ENV_SH\"; declare -F __povy_path_front; echo \"[\${__povy_p:-}]\""
  [ "$output" = '[]' ]
}

@test "without contexts, interactive.sh only shows the banner; with banner = false, it does nothing" {
  CFG_BANNER=true
  shell_write_interactive
  [ "$(grep -c 'banner --auto' "$POVY_INTERACTIVE_SH")" -eq 1 ]
  [ "$(grep -cv '^#' "$POVY_INTERACTIVE_SH")" -eq 5 ]
  ! grep -qE '(^|[[:space:]])(\.|source|eval) ' "$POVY_INTERACTIVE_SH" || false
  CFG_BANNER=false
  shell_write_interactive
  [ "$(grep -cv '^#' "$POVY_INTERACTIVE_SH")" -eq 0 ]
}

@test "only the files that interactive shells read load the banner" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  shell_apply_blocks
  grep -qF '.config/povy/env.sh' "$HOME/.zshenv"
  ! grep -qF 'interactive.sh' "$HOME/.zshenv" || false
  ! grep -qF 'interactive.sh' "$HOME/.zprofile" || false
  grep -qF '.config/povy/interactive.sh' "$HOME/.zshrc"
  ! grep -qF 'env.sh' "$HOME/.zshrc" || false
  grep -qF 'env.sh' "$HOME/.bashrc"
  grep -qF 'interactive.sh' "$HOME/.bashrc"
}

@test ".bashrc keeps env at the top and gets a named interactive block at the bottom" {
  printf 'case $- in *i*) ;; *) return ;; esac\nalias ll="ls -l"\n' >"$HOME/.bashrc"
  apply_shell
  [ "$(head -n 1 "$HOME/.bashrc")" = '# >>> povy >>>' ]
  [ "$(tail -n 1 "$HOME/.bashrc")" = '# <<< povy interactive <<<' ]
  [ "$(awk '/^# <<< povy <<<$/ { exit } { print }' "$HOME/.bashrc" | grep -c interactive.sh)" -eq 0 ]
}

@test "the earlier layout moves: .zshrc to the end, .bashrc split in two" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  printf 'export MINE=1\n' >"$HOME/.zshrc"
  printf 'export MINE=1\n' >"$HOME/.bashrc"
  shell_block_apply "$HOME/.zshrc" interactive top
  shell_block_apply "$HOME/.bashrc" "env interactive" top
  # A new run: same process and second here, so its backup directory is set apart.
  POVY_BACKUP_DIR=$BATS_TEST_TMPDIR/second-run
  apply_shell
  [ "$(head -n 1 "$HOME/.zshrc")" = 'export MINE=1' ]
  [ "$(tail -n 1 "$HOME/.zshrc")" = '# <<< povy <<<' ]
  [ "$(grep -c '^# >>> povy' "$HOME/.zshrc")" -eq 1 ]
  [ "$(head -n 1 "$HOME/.bashrc")" = '# >>> povy >>>' ]
  [ "$(tail -n 1 "$HOME/.bashrc")" = '# <<< povy interactive <<<' ]
  [ "$(grep -c 'interactive.sh' "$HOME/.bashrc")" -eq 1 ]
  grep -qxF 'export MINE=1' "$HOME/.bashrc"
  # .bashrc changed twice: its backup is the file as it was before, both parts in one block.
  local backup=$POVY_BACKUP_DIR/.bashrc
  ! grep -q '# >>> povy interactive >>>' "$backup" || false
  grep -q 'interactive.sh' "$backup"
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
  [[ "$output" == "$POVY_SHIMS_DIR:"* ]] || false
}

# A tool in the shims, in an install directory of mise and in another directory.
fake_tool_dirs() {
  export MISE_DATA_DIR=$BATS_TEST_TMPDIR/mise-data
  povy_init_paths
  INSTALLS=$MISE_DATA_DIR/installs/jq/1.7.1/bin
  OTHER=$HOME/other/installs/jq/bin
  local dir
  for dir in "$POVY_SHIMS_DIR" "$INSTALLS" "$OTHER"; do
    mkdir -p "$dir"
    printf '#!/bin/sh\n' >"$dir/jq"
    chmod +x "$dir/jq"
  done
}

@test "a directory before the shims hides their commands, unless it is one of mise's installs" {
  fake_tool_dirs
  [ -z "$(shims_shadowed "$INSTALLS:$POVY_SHIMS_DIR:/usr/bin" jq)" ]
  [ "$(shims_shadowed "$INSTALLS:$OTHER:$POVY_SHIMS_DIR" jq)" = "jq"$'\t'"$OTHER" ]
  [ -z "$(shims_shadowed "$POVY_SHIMS_DIR:$OTHER" jq)" ]
  # Without the shims on PATH, nothing is hidden.
  [ -z "$(shims_shadowed "$OTHER:/usr/bin" jq)" ]
  [ "$(shims_shadowed_summary "jq"$'\t'"$OTHER")" = "~/other/installs/jq/bin hides jq" ]
}
