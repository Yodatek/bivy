#!/usr/bin/env bats

load helper

setup_file() {
  export REAL_HOME=$HOME
  sandbox_env "$BATS_FILE_TMPDIR/seed"
  export MISE_DATA_DIR="$BATS_SUITE_TMPDIR/mise-data"
  export MISE_CACHE_DIR="$BATS_SUITE_TMPDIR/mise-cache"
  write_config "$BATS_FILE_TMPDIR/config.toml"
  povy init --config "$BATS_FILE_TMPDIR/config.toml"
  povy apply
}

setup() {
  sandbox_setup
  cp -R "$BATS_FILE_TMPDIR/seed/." "$HOME/"
}

gui_file() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/LaunchAgents/povy.env.plist" ;;
    *) echo "$HOME/.config/environment.d/50-povy.conf" ;;
  esac
}

@test "healthy state exits 0" {
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "doctor changes nothing" {
  local before
  before=$(home_fingerprint)
  run povy doctor
  [ "$before" = "$(home_fingerprint)" ]
}

@test "missing configuration exits 1" {
  rm "$HOME/.config/povy/config.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"config.toml is missing"* ]]
}

@test "invalid configuration exits 1" {
  echo 'name = "oops' >"$HOME/.config/povy/config.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"is invalid"* ]]
}

@test "a readable .env exits 1" {
  chmod 644 "$HOME/.config/povy/.env"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 644"* ]]
}

@test "a missing .env exits 1" {
  rm "$HOME/.config/povy/.env"
  run povy doctor
  [ "$status" -eq 1 ]
}

@test "a removed startup block exits 1" {
  : >"$HOME/.bashrc"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"no povy block"* ]]
}

@test "shims not reachable from a login shell exits 1" {
  local login
  login=$(find "$HOME" -maxdepth 1 \( -name .bash_profile -o -name .bash_login -o -name .profile \) | head -n 1)
  printf '# >>> povy >>>\n# <<< povy <<<\n' >"$login"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"shims not visible from a non-interactive 'bash -lc'"* ]]
}

@test "missing mise exits 1 and does not crash" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  local tool
  for tool in bash env sh uname grep tail head stat dirname readlink zsh git awk tr mktemp cmp rm cat sed; do
    ln -s "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool" 2>/dev/null || true
  done
  PATH=$BATS_TEST_TMPDIR/bin run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"mise is not installed"* ]]
}

@test "doctor reports empty required secrets" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty secrets"*EXAMPLE_API_TOKEN* ]]
}

@test "doctor never prints secret values" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  echo 'EXAMPLE_API_TOKEN=do-not-print' >>"$HOME/.config/povy/.env"
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *do-not-print* ]]
}

@test "a managed file with loose permissions exits 1" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  echo 'EXAMPLE_API_TOKEN=x' >>"$HOME/.config/povy/.env"
  povy apply
  chmod 644 "$HOME/.config/povy-example/example.conf"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"example.conf has mode 644"* ]]
}

@test "a removed file for graphical apps exits 1" {
  rm "$(gui_file)"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(gui_file) is missing"* ]]
}

@test "macOS: doctor reads the PATH of graphical apps" {
  [ "$(uname -s)" = Darwin ] || skip "macOS only"
  run povy doctor
  [[ "$output" == *"[warn] graphical apps started now do not see the shims"* ]]
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   shims on the PATH of graphical apps"* ]]
}

@test "a removed Git block exits 1" {
  printf '[core]\n' >"$HOME/.gitconfig"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"no povy block in $HOME/.gitconfig"* ]]
}

@test "an identity added to config.toml without apply exits 1" {
  printf '\n[[identities]]\ndir = "~/oss/"\nemail = "oss@example.org"\n' >>"$HOME/.config/povy/config.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match config.toml"* ]]
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"and 1 by directory"* ]]
}

@test "a [user] after the povy include is a warning, not a failure" {
  printf '[user]\n\temail = old@example.org\n' >>"$HOME/.gitconfig"
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn]"*"$HOME/.gitconfig"* ]]
}

@test "a login file that puts a directory before the shims is reported" {
  mkdir -p "$HOME/fakebin"
  printf '#!/bin/sh\necho fake\n' >"$HOME/fakebin/yq"
  chmod +x "$HOME/fakebin/yq"
  local login
  login=$(find "$HOME" -maxdepth 1 \( -name .bash_profile -o -name .bash_login -o -name .profile \) | head -n 1)
  printf 'export PATH="$HOME/fakebin:$PATH"\n' >>"$login"
  run povy doctor
  echo "$output"
  [[ "$output" == *"in 'bash -lc', ~/fakebin hides yq before the mise shims"* ]]
}
