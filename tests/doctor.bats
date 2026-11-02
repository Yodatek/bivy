#!/usr/bin/env bats

load helper

setup_file() {
  export REAL_HOME=$HOME
  sandbox_env "$BATS_FILE_TMPDIR/seed"
  export MISE_DATA_DIR="$BATS_SUITE_TMPDIR/mise-data"
  export MISE_CACHE_DIR="$BATS_SUITE_TMPDIR/mise-cache"
  write_config "$BATS_FILE_TMPDIR/config.toml"
  bivy init --config "$BATS_FILE_TMPDIR/config.toml"
  bivy apply
}

setup() {
  sandbox_setup
  cp -R "$BATS_FILE_TMPDIR/seed/." "$HOME/"
}

@test "healthy state exits 0" {
  run bivy doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

@test "doctor changes nothing" {
  local before
  before=$(home_fingerprint)
  run bivy doctor
  [ "$before" = "$(home_fingerprint)" ]
}

@test "missing configuration exits 1" {
  rm "$HOME/.config/bivy/config.toml"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"config.toml is missing"* ]]
}

@test "invalid configuration exits 1" {
  echo 'name = "oops' >"$HOME/.config/bivy/config.toml"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"is invalid"* ]]
}

@test "a readable .env exits 1" {
  chmod 644 "$HOME/.config/bivy/.env"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 644"* ]]
}

@test "a missing .env exits 1" {
  rm "$HOME/.config/bivy/.env"
  run bivy doctor
  [ "$status" -eq 1 ]
}

@test "a removed startup block exits 1" {
  : >"$HOME/.bashrc"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"no bivy block"* ]]
}

@test "shims not reachable from a login shell exits 1" {
  local login
  login=$(find "$HOME" -maxdepth 1 \( -name .bash_profile -o -name .bash_login -o -name .profile \) | head -n 1)
  printf '# >>> bivy >>>\n# <<< bivy <<<\n' >"$login"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"shims not visible from a non-interactive 'bash -lc'"* ]]
}

@test "missing mise exits 1 and does not crash" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  local tool
  for tool in bash env sh uname grep tail head stat dirname readlink zsh git awk tr; do
    ln -s "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool" 2>/dev/null || true
  done
  PATH=$BATS_TEST_TMPDIR/bin run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"mise is not installed"* ]]
}

@test "doctor reports empty required secrets" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  bivy init --config "$BATS_TEST_TMPDIR/c.toml"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty secrets"*EXAMPLE_API_TOKEN* ]]
}

@test "doctor never prints secret values" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  bivy init --config "$BATS_TEST_TMPDIR/c.toml"
  echo 'EXAMPLE_API_TOKEN=do-not-print' >>"$HOME/.config/bivy/.env"
  bivy apply
  run bivy doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *do-not-print* ]]
}

@test "a managed file with loose permissions exits 1" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  bivy init --config "$BATS_TEST_TMPDIR/c.toml"
  echo 'EXAMPLE_API_TOKEN=x' >>"$HOME/.config/bivy/.env"
  bivy apply
  chmod 644 "$HOME/.config/bivy-example/example.conf"
  run bivy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"example.conf has mode 644"* ]]
}
