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

login_file() {
  find "$HOME" -maxdepth 1 \( -name .bash_profile -o -name .bash_login -o -name .profile \) | head -n 1
}

# init and apply with the example profile and its secret.
apply_example() {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  echo "EXAMPLE_API_TOKEN=${1:-x}" >>"$HOME/.config/povy/.env"
  povy apply
}

# A mise that reports the version given, and is the real one otherwise.
stub_mise_version() {
  local real
  real=$(command -v mise)
  mkdir -p "$BATS_TEST_TMPDIR/old"
  cat >"$BATS_TEST_TMPDIR/old/mise" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then
  echo "$1 macos-arm64 (2026-01-01)"
  exit 0
fi
exec "$real" "\$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/old/mise"
}

@test "healthy state exits 0" {
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   mise 20"* ]] || false
  [[ "$output" == *"[ok]   mise config: ~/.config/mise/conf.d/povy.toml"* ]] || false
  [[ "$output" != *FAIL* ]] || false
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
  [[ "$output" == *"config.toml is missing"* ]] || false
}

@test "invalid configuration exits 1" {
  echo 'name = "oops' >"$HOME/.config/povy/config.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"is invalid"* ]] || false
}

@test "a config.toml with povy 0.1 settings exits 1 and says where they go" {
  printf 'prompt = "starship"\n[tools]\njq = "1.7.1"\n' >>"$HOME/.config/povy/config.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] $HOME/.config/povy/config.toml is invalid: "*"since povy 0.2, tools, packages and the prompt are mise configuration"* ]] || false
}

@test "a readable .env exits 1" {
  chmod 644 "$HOME/.config/povy/.env"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 644"* ]] || false
}

@test "a missing .env exits 1" {
  rm "$HOME/.config/povy/.env"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *".env is missing; run: povy init"* ]] || false
}

@test "a removed startup block exits 1" {
  : >"$HOME/.bashrc"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"no povy block in $HOME/.bashrc"* ]] || false
}

@test "shims not reachable from a login shell exits 1" {
  printf '# >>> povy >>>\n# <<< povy <<<\n' >"$(login_file)"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"shims not visible from a non-interactive 'bash -lc'"* ]] || false
}

@test "missing mise exits 1 and does not crash" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  local tool
  for tool in bash env sh uname grep tail head stat dirname readlink zsh git awk tr mktemp cmp rm cat sed sort; do
    ln -s "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool" 2>/dev/null || true
  done
  PATH=$BATS_TEST_TMPDIR/bin run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] mise is not installed"* ]] || false
}

@test "a mise older than 2026.11 exits 1, and init and apply refuse to run" {
  stub_mise_version 2026.10.3
  PATH="$BATS_TEST_TMPDIR/old:$PATH" run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] mise 2026.10.3 macos-arm64 (2026-01-01) is older than 2026.11.0"* ]] || false
  PATH="$BATS_TEST_TMPDIR/old:$PATH" run povy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"povy needs mise 2026.11.0 or later"* ]] || false
  PATH="$BATS_TEST_TMPDIR/old:$PATH" run povy init --config "$HOME/.config/povy/config.toml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"povy needs mise 2026.11.0 or later"* ]] || false
}

@test "mise versions are compared field by field" {
  load_libs
  local version
  stub_mise_version '$MISE_STUB_VERSION'
  PATH="$BATS_TEST_TMPDIR/old:$PATH"
  for version in 2026.11.0 2026.11.11 2026.12.1 2027.1.0; do
    MISE_STUB_VERSION=$version mise_recent_enough || {
      echo "refused: $version"
      return 1
    }
  done
  for version in 2026.10.99 2026.9.30 2025.12.0; do
    ! MISE_STUB_VERSION=$version mise_recent_enough || {
      echo "accepted: $version"
      return 1
    }
  done
}

@test "a mise config changed by hand exits 1, and apply puts it back" {
  local conf=$HOME/.config/mise/conf.d/povy.toml
  printf '[env]\nBY_HAND = "1"\n' >>"$conf"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] $conf is outdated; run: povy apply"* ]] || false
  rm "$conf"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] $conf is missing; run: povy apply"* ]] || false
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
}

@test "doctor reports empty required secrets" {
  make_profile_repo "$BATS_TEST_TMPDIR/p"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$BATS_TEST_TMPDIR/p"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] empty secrets in $HOME/.config/povy/.env: EXAMPLE_API_TOKEN"* ]] || false
}

@test "doctor never prints secret values" {
  apply_example do-not-print
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   the secrets the profile needs are set"* ]] || false
  [[ "$output" != *do-not-print* ]] || false
}

@test "a file of the profile's mise.toml changed by hand exits 1, and apply repairs it" {
  local file=$HOME/.config/povy-example/example.conf
  apply_example
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   mise bootstrap: the profile's mise.toml is applied"* ]] || false

  echo 'edited by hand' >>"$file"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] the profile's mise.toml is not fully applied; run: povy apply"* ]] || false
  povy apply
  ! grep -qF 'edited by hand' "$file" || false
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"povy doctor: all good."* ]] || false

  chmod 644 "$file"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] the profile's mise.toml is not fully applied"* ]] || false
  povy apply
  [ "$(file_mode "$file")" = 600 ]
  run povy doctor
  [ "$status" -eq 0 ]
}

@test "a removed file for graphical apps exits 1" {
  rm "$(gui_file)"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(gui_file) is missing"* ]] || false
}

@test "macOS: doctor reads the PATH of graphical apps" {
  [ "$(uname -s)" = Darwin ] || skip "macOS only"
  run povy doctor
  [[ "$output" == *"[warn] graphical apps started now do not see the shims"* ]] || false
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   shims on the PATH of graphical apps"* ]] || false
}

@test "a removed Git block exits 1" {
  printf '[core]\n' >"$HOME/.gitconfig"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"no povy block in $HOME/.gitconfig"* ]] || false
}

@test "an identity added to config.toml without apply exits 1" {
  printf '\n[[identities]]\ndir = "~/oss/"\nemail = "oss@example.org"\n' >>"$HOME/.config/povy/config.toml"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match config.toml"* ]] || false
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"and 1 by directory"* ]] || false
}

@test "a [user] after the povy include is a warning, not a failure" {
  printf '[user]\n\temail = old@example.org\n' >>"$HOME/.gitconfig"
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[warn]"*"$HOME/.gitconfig"* ]] || false
}

@test "a login file that puts a directory before the shims is reported" {
  mkdir -p "$HOME/fakebin"
  printf '#!/bin/sh\necho fake\n' >"$HOME/fakebin/yq"
  chmod +x "$HOME/fakebin/yq"
  printf 'export PATH="$HOME/fakebin:$PATH"\n' >>"$(login_file)"
  run povy doctor
  echo "$output"
  [[ "$output" == *"[warn] in 'bash -lc', ~/fakebin hides yq before the mise shims"* ]] || false
}

# mise activate puts the install directories of the active tools first, on purpose.
installs_before_shims() {
  local dir
  dir=$(cd "$HOME" && mise bin-paths | grep -F "$MISE_DATA_DIR/installs/yq/" | head -n 1)
  [ -x "$dir/yq" ]
  printf 'export PATH="%s:$PATH"\n' "$dir" >>"$(login_file)"
}

@test "a directory of mise's installs before the shims is not reported as hiding them" {
  installs_before_shims
  run povy doctor
  echo "$output"
  [[ "$output" != *"hides"* ]] || false
}

@test "a directory of mise's installs before the shims leaves doctor all good" {
  installs_before_shims
  run povy doctor
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "with ZDOTDIR, the env block goes in both .zshenv files and doctor checks both" {
  command -v zsh >/dev/null || skip "zsh is not installed"
  export ZDOTDIR=$HOME/.config/zsh
  mkdir -p "$ZDOTDIR"
  povy apply
  grep -qxF '# >>> povy >>>' "$HOME/.zshenv"
  grep -qxF '# >>> povy >>>' "$ZDOTDIR/.zshenv"
  grep -qF 'interactive.sh' "$ZDOTDIR/.zshrc"
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   povy block in $ZDOTDIR/.zshenv"* ]] || false
  [[ "$output" == *"[ok]   povy block in $HOME/.zshenv"* ]] || false
  : >"$ZDOTDIR/.zshenv"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] no povy block in $ZDOTDIR/.zshenv"* ]] || false
}
