#!/usr/bin/env bats
# Git identity, without mise tools: the libraries are driven directly.

load helper

setup() {
  sandbox_setup
  load_libs
  yq_ensure
  CONFIG=$BATS_TEST_TMPDIR/config.toml
  write_config "$CONFIG"
  cd "$HOME"
}

# Appends an [[identities]] entry to the test configuration. Values are TOML
# string contents, so quotes must already be escaped.
add_identity() {
  {
    echo
    echo '[[identities]]'
    printf 'dir = "%s"\n' "$1"
    printf 'email = "%s"\n' "$2"
    [ -z "${3:-}" ] || printf 'name = "%s"\n' "$3"
  } >>"$CONFIG"
}

apply_git() {
  config_read "$CONFIG"
  git_apply
}

new_repo() {
  mkdir -p "$1"
  git init --quiet "$1"
}

global_email() {
  git config --global --includes --get user.email
}

# Prints the file without the povy block.
outside_block() {
  awk '$0 == "# >>> povy >>>" { on = 1 } !on { print } $0 == "# <<< povy <<<" { on = 0 }' "$1"
}

@test "the block goes on top of ~/.gitconfig, whose content stays byte for byte" {
  printf '[core]\n\teditor = vi\n[alias]\n\tst = status' >"$HOME/.gitconfig"
  cp "$HOME/.gitconfig" "$BATS_TEST_TMPDIR/before"
  apply_git
  [ "$(head -n 1 "$HOME/.gitconfig")" = '# >>> povy >>>' ]
  outside_block "$HOME/.gitconfig" >"$BATS_TEST_TMPDIR/after"
  printf '\n' >>"$BATS_TEST_TMPDIR/before"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  grep -qxF $'\tpath = ~/.config/povy/git/config' "$HOME/.gitconfig"
  [ "$(global_email)" = test@example.org ]
  [ "$(git config --global --includes --get user.name)" = "Test User" ]
}

@test "a repository under an identity directory gets that identity, the name defaulting to the main one" {
  add_identity "~/perso" "me@users.noreply.example.org"
  apply_git
  new_repo "$HOME/perso/tool"
  new_repo "$HOME/work/app"
  [ "$(git -C "$HOME/perso/tool" config user.email)" = me@users.noreply.example.org ]
  [ "$(git -C "$HOME/perso/tool" config user.name)" = "Test User" ]
  [ "$(git -C "$HOME/work/app" config user.email)" = test@example.org ]
  grep -qF '[includeIf "gitdir:~/perso/"]' "$HOME/.config/povy/git/config"
}

@test "names and directories with quotes and spaces reach Git as written" {
  add_identity "~/my \\\"own\\\" dir/" "ada@example.org" 'Ada \"The Countess\" Lovelace'
  apply_git
  new_repo "$HOME/my \"own\" dir/repo"
  [ "$(git -C "$HOME/my \"own\" dir/repo" config user.name)" = 'Ada "The Countess" Lovelace' ]
  [ "$(git -C "$HOME/my \"own\" dir/repo" config user.email)" = ada@example.org ]
}

@test "an absolute directory works, even through a symlink" {
  mkdir -p "$BATS_TEST_TMPDIR/real/projects"
  ln -s real "$BATS_TEST_TMPDIR/link"
  add_identity "$BATS_TEST_TMPDIR/link/projects" "abs@example.org"
  apply_git
  new_repo "$BATS_TEST_TMPDIR/link/projects/repo"
  [ "$(git -C "$BATS_TEST_TMPDIR/link/projects/repo" config user.email)" = abs@example.org ]
}

@test "an absolute directory that does not exist yet is written as given" {
  add_identity "$BATS_TEST_TMPDIR/elsewhere" "abs@example.org"
  apply_git
  grep -qF "gitdir:$BATS_TEST_TMPDIR/elsewhere/" "$HOME/.config/povy/git/config"
}

@test "an absolute directory works too" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  add_identity "$BATS_TEST_TMPDIR/elsewhere" "abs@example.org"
  apply_git
  new_repo "$BATS_TEST_TMPDIR/elsewhere/repo"
  [ "$(git -C "$BATS_TEST_TMPDIR/elsewhere/repo" config user.email)" = abs@example.org ]
}

@test "a second run changes nothing and makes no backup" {
  add_identity "~/perso/" "me@example.org"
  echo '[core]' >"$HOME/.gitconfig"
  apply_git
  local before
  before=$(home_fingerprint)
  POVY_WRITTEN=0
  POVY_BACKED_UP=0
  apply_git
  [ "$POVY_WRITTEN" -eq 0 ]
  [ "$POVY_BACKED_UP" -eq 0 ]
  [ "$before" = "$(home_fingerprint)" ]
}

@test "the original global config is backed up before the first change" {
  echo '[core]' >"$HOME/.gitconfig"
  apply_git
  local found
  found=$(find "$HOME/.local/state/povy/backups" -name .gitconfig)
  [ "$(cat "$found")" = '[core]' ]
}

@test "a removed identity is cleaned up" {
  add_identity "~/a/" "a@example.org"
  add_identity "~/b/" "b@example.org"
  apply_git
  [ -f "$HOME/.config/povy/git/identity-2" ]
  write_config "$CONFIG"
  add_identity "~/a/" "a@example.org"
  apply_git
  [ ! -e "$HOME/.config/povy/git/identity-2" ]
  ! grep -qF 'gitdir:~/b/' "$HOME/.config/povy/git/config" || false
}

@test "a [user] after the block is reported with its file, an included one too" {
  add_identity "~/perso/" "me@example.org"
  printf '[user]\n\temail = old@example.org\n[include]\n\tpath = extra.conf\n' >"$HOME/.gitconfig"
  printf '[user]\n\tname = Old Name\n' >"$HOME/extra.conf"
  run apply_git
  [ "$status" -eq 0 ]
  [[ "$output" == *"override it"* ]] || false
  [[ "$output" == *"$HOME/.gitconfig"* ]] || false
  [[ "$output" == *"$HOME/extra.conf"* ]] || false
  # This is why it matters: the [user] wins even in an identity directory.
  new_repo "$HOME/perso/repo"
  [ "$(git -C "$HOME/perso/repo" config user.email)" = old@example.org ]
}

@test "no warning when nothing comes after the block" {
  printf '[core]\n\teditor = vi\n' >"$HOME/.gitconfig"
  run apply_git
  [ "$status" -eq 0 ]
  [[ "$output" != *"override"* ]] || false
}

@test "the XDG file is used when ~/.gitconfig does not exist" {
  mkdir -p "$HOME/.config/git"
  echo '[core]' >"$HOME/.config/git/config"
  apply_git
  [ ! -e "$HOME/.gitconfig" ]
  [ "$(head -n 1 "$HOME/.config/git/config")" = '# >>> povy >>>' ]
  [ "$(global_email)" = test@example.org ]
}

@test "a symlinked ~/.gitconfig stays a symlink and its target gets the block" {
  mkdir -p "$HOME/dotfiles"
  echo '[core]' >"$HOME/dotfiles/gitconfig"
  ln -s dotfiles/gitconfig "$HOME/.gitconfig"
  apply_git
  [ -L "$HOME/.gitconfig" ]
  [ "$(head -n 1 "$HOME/dotfiles/gitconfig")" = '# >>> povy >>>' ]
}

@test "invalid identities are refused by init, which writes nothing" {
  local body
  for body in \
    $'[identities]\ndir = "~/a/"\nemail = "a@example.org"' \
    $'[[identities]]\ndir = "relative/"\nemail = "a@example.org"' \
    $'[[identities]]\ndir = "~/"\nemail = "a@example.org"' \
    $'[[identities]]\nemail = "a@example.org"' \
    $'[[identities]]\ndir = "~/a/"' \
    $'[[identities]]\ndir = "~/a/"\nemail = "not-an-address"' \
    $'[[identities]]\ndir = "~/a/"\nemail = "a@example.org"\nname = 3' \
    'identities = ["~/a/"]'; do
    write_config "$CONFIG"
    printf '%s\n' "$body" >>"$CONFIG"
    run povy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $body"
      return 1
    }
    [[ "$output" == *identities* ]] || false
    [ ! -e "$HOME/.config/povy/config.toml" ]
  done
}
