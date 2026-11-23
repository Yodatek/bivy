#!/usr/bin/env bats

load helper

setup() {
  sandbox_setup
  CONFIG=$BATS_TEST_TMPDIR/config.toml
}

answers() {
  export POVY_TTY=$BATS_TEST_TMPDIR/tty
  printf '%s\n' "$@" >"$POVY_TTY"
}

# An editor that records its call and optionally fills a secret.
stub_editor() {
  export EDITOR=$BATS_TEST_TMPDIR/editor
  cat >"$EDITOR" <<SCRIPT
#!/bin/sh
echo "\$1" >>"$BATS_TEST_TMPDIR/editor.log"
${1:-:}
SCRIPT
  chmod +x "$EDITOR"
}

@test "--config installs the file and creates .env in 600" {
  write_config "$CONFIG"
  run povy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  cmp "$CONFIG" "$HOME/.config/povy/config.toml"
  [ "$(file_mode "$HOME/.config/povy/.env")" = 600 ]
  [ "$(file_mode "$HOME/.config/povy/config.toml")" = 600 ]
}

@test "--config never opens the editor, even with empty secrets" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$CONFIG" "$BATS_TEST_TMPDIR/p"
  stub_editor
  run povy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/editor.log" ]
  [[ "$output" == *EXAMPLE_API_TOKEN* ]] || false
  grep -qxF 'EXAMPLE_API_TOKEN=' "$HOME/.config/povy/.env"
}

@test "--config accepts a relative path" {
  write_config "$CONFIG"
  cd "$BATS_TEST_TMPDIR"
  run povy init --config config.toml
  [ "$status" -eq 0 ]
}

@test "--config rejects invalid input and writes nothing" {
  local body
  for body in \
    'name = "unterminated' \
    'email = "a@b.c"' \
    $'name = "A"\nemail = "not-an-address"' \
    $'name = 3\nemail = "a@b.c"' \
    $'name = "A"\nemail = "a@b.c"\nprofile = "https://me:hunter2@example.org/p.git"' \
    $'name = "A"\nemail = "a@b.c"\nprofile = "--upload-pack=x"' \
    $'name = "A"\nemail = "a@b.c"\nprofile = "ext::sh -c x"' \
    $'name = "A\\n[core]"\nemail = "a@b.c"' \
    $'name = "A"\nemail = "a@b.c\\n[user]"' \
    $'name = "A"\nemail = "a@b.c"\nprofile = "/p\\n[core]"'; do
    printf '%s\n' "$body" >"$CONFIG"
    run povy init --config "$CONFIG"
    [ "$status" -ne 0 ]
    [ ! -e "$HOME/.config/povy/config.toml" ]
  done
}

@test "povy 0.1 settings in config.toml are refused, by init and by apply, with where they go" {
  local body key
  for body in $'[tools]\njq = "1.7.1"' $'[packages]\nbrew = ["podman"]' 'prompt = "starship"'; do
    key=${body%%[] =]*}
    key=${key#[}
    write_config "$CONFIG"
    printf '%s\n' "$body" >>"$CONFIG"
    run povy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $body"
      return 1
    }
    [[ "$output" == *"$CONFIG: $key: since povy 0.2, tools, packages and the prompt are mise configuration; move them to ~/.config/mise/config.toml or to the profile's team.toml and mise.toml"* ]] || false
    [ ! -e "$HOME/.config/povy/config.toml" ]
  done

  # A machine that povy 0.1 configured.
  mkdir -p "$HOME/.config/povy"
  write_config "$HOME/.config/povy/config.toml"
  printf 'prompt = "starship"\n[tools]\njq = "1.7.1"\n' >>"$HOME/.config/povy/config.toml"
  run povy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.toml: prompt tools: since povy 0.2"* ]] || false
  [ ! -e "$HOME/.zshenv" ]
  [ ! -e "$HOME/.config/mise/conf.d/povy.toml" ]
}

@test "--config without a file is an error" {
  run povy init --config
  [ "$status" -ne 0 ]
}

@test "the three questions are read from the terminal, stdin is left alone" {
  answers 'Ana "Ace" O\Neil' 'ana@example.org' ''
  run povy init </dev/null
  [ "$status" -eq 0 ]
  run povy doctor
  grep -qF 'name = "Ana \"Ace\" O\\Neil"' "$HOME/.config/povy/config.toml"
  grep -qxF 'email = "ana@example.org"' "$HOME/.config/povy/config.toml"
  grep -qxF 'profile = ""' "$HOME/.config/povy/config.toml"
}

@test "an invalid e-mail is asked again" {
  answers 'Ana' 'nope' 'ana@example.org' ''
  run povy init
  [ "$status" -eq 0 ]
  grep -qxF 'email = "ana@example.org"' "$HOME/.config/povy/config.toml"
}

@test "without a terminal, init explains how to run without questions" {
  run povy init
  [ "$status" -ne 0 ]
  [[ "$output" == *"--config"* ]] || false
}

@test "a truncated answer stream fails instead of looping" {
  answers 'Ana'
  run povy init
  [ "$status" -ne 0 ]
}

@test "the editor opens when the profile requires empty secrets" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  answers 'Ana' 'ana@example.org' "$BATS_TEST_TMPDIR/p"
  stub_editor "echo EXAMPLE_API_TOKEN=abc >>\"\$1\""
  run povy init
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/editor.log")" = "$HOME/.config/povy/.env" ]
  [[ "$output" != *"fill these secrets"* ]] || false
  [ "$(file_mode "$HOME/.config/povy/.env")" = 600 ]
}

@test "the editor stays closed when no profile needs a secret" {
  answers 'Ana' 'ana@example.org' ''
  stub_editor
  run povy init
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "the editor stays closed when the secrets are already filled" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  mkdir -p "$HOME/.config/povy"
  echo 'EXAMPLE_API_TOKEN=abc' >"$HOME/.config/povy/.env"
  answers 'Ana' 'ana@example.org' "$BATS_TEST_TMPDIR/p"
  stub_editor
  run povy init
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/editor.log" ]
}

@test "an EDITOR with arguments works" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  answers 'Ana' 'ana@example.org' "$BATS_TEST_TMPDIR/p"
  stub_editor
  export EDITOR="$EDITOR --wait"
  run povy init
  [ "$status" -eq 0 ]
  grep -qxF -- --wait "$BATS_TEST_TMPDIR/editor.log"
}

@test "an existing .env keeps its content and gets its mode fixed" {
  write_config "$CONFIG"
  mkdir -p "$HOME/.config/povy"
  echo 'KEEP=me' >"$HOME/.config/povy/.env"
  chmod 644 "$HOME/.config/povy/.env"
  run povy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  grep -qxF 'KEEP=me' "$HOME/.config/povy/.env"
  [ "$(file_mode "$HOME/.config/povy/.env")" = 600 ]
}

@test "init --config on the installed file is a no-op" {
  write_config "$CONFIG"
  povy init --config "$CONFIG"
  run povy init --config "$HOME/.config/povy/config.toml"
  [ "$status" -eq 0 ]
  cmp "$CONFIG" "$HOME/.config/povy/config.toml"
}

@test "a replaced configuration is backed up" {
  write_config "$CONFIG"
  povy init --config "$CONFIG"
  sed 's/Test User/Other/' "$CONFIG" >"$CONFIG.2"
  povy init --config "$CONFIG.2"
  [ -n "$(find "$HOME/.local/state/povy/backups" -name config.toml)" ]
}

@test "answering the questions again keeps the rest of config.toml" {
  local file=$HOME/.config/povy/config.toml
  write_config "$CONFIG"
  printf 'banner = false\n\n[[identities]]\ndir = "~/oss/"\nemail = "oss@example.org"\n' >>"$CONFIG"
  povy init --config "$CONFIG"
  answers "New Name" "" none
  run povy init
  [ "$status" -eq 0 ]
  grep -qxF 'name = "New Name"' "$file"
  grep -qxF 'email = "test@example.org"' "$file"
  grep -qxF 'banner = false' "$file"
  grep -qxF 'dir = "~/oss/"' "$file"
  [ "$(grep -c '^name = ' "$file")" -eq 1 ]

  cp "$file" "$BATS_TEST_TMPDIR/before"
  answers "New Name" "" none
  povy init
  cmp "$BATS_TEST_TMPDIR/before" "$file"
}
