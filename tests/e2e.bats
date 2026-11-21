#!/usr/bin/env bats
# The whole path with real mise and default locations: init --config, apply, doctor.

load helper

real_home_snapshot() {
  local f
  for f in .zshrc .zshenv .zprofile .bashrc .bash_profile .profile .gitconfig .config/git/config \
    .ssh/config .m2/settings.xml .config/povy/config.toml .config/mise/conf.d/povy.toml \
    Library/LaunchAgents/povy.env.plist .config/environment.d/50-povy.conf; do
    if [ -e "$REAL_HOME/$f" ]; then
      printf '%s %s\n' "$f" "$(cksum <"$REAL_HOME/$f")"
    else
      printf '%s absent\n' "$f"
    fi
  done
  if [ -x /bin/launchctl ]; then
    printf 'launchctl PATH=%s\n' "$(/bin/launchctl getenv PATH)"
  fi
}

setup_file() {
  export REAL_HOME=$HOME
  real_home_snapshot >"$BATS_FILE_TMPDIR/real-before"
  sandbox_env "$BATS_FILE_TMPDIR/home"
  make_profile_repo "$BATS_FILE_TMPDIR/profile"
  write_config "$BATS_FILE_TMPDIR/config.toml" "$BATS_FILE_TMPDIR/profile"
  printf '# mine\nexport MINE=1\n' >"$HOME/.zshenv"
  echo "user content" >"$BATS_FILE_TMPDIR/old.conf"
  mkdir -p "$HOME/.config/povy-example"
  cp "$BATS_FILE_TMPDIR/old.conf" "$HOME/.config/povy-example/example.conf"

  povy init --config "$BATS_FILE_TMPDIR/config.toml"
  echo 'EXAMPLE_API_TOKEN=s3cret&\value' >>"$HOME/.config/povy/.env"
  povy apply >"$BATS_FILE_TMPDIR/apply.log" 2>&1
}

setup() {
  export HOME=$BATS_FILE_TMPDIR/home
}

@test "doctor passes after init --config and apply" {
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"all good"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "secrets file has mode 600" {
  [ "$(file_mode "$HOME/.config/povy/.env")" = 600 ]
}

@test "the template is rendered with mode 600, the secret verbatim" {
  local target="$HOME/.config/povy-example/example.conf"
  [ "$(file_mode "$target")" = 600 ]
  grep -qxF 'user = Test User' "$target"
  grep -qxF 'token = s3cret&\value' "$target"
  grep -qxF "cache = $HOME/.cache/povy-example" "$target"
}

@test "the replaced file is backed up with its content" {
  local found
  found=$(find "$HOME/.local/state/povy/backups" -name example.conf)
  [ -n "$found" ]
  grep -qxF 'user content' "$found"
  [ "$(file_mode "$found")" = 600 ]
}

@test "existing startup content is kept" {
  grep -qxF 'export MINE=1' "$HOME/.zshenv"
  [ "$(head -n 1 "$HOME/.zshenv")" = '# >>> povy >>>' ]
}

@test "profile tools run from non-interactive shells with an empty environment" {
  cd "$HOME"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -lc 'jq --version'
  [ "$status" -eq 0 ]
  [ "$output" = jq-1.7.1 ]
  if command -v zsh >/dev/null; then
    run env -i HOME="$HOME" PATH=/usr/bin:/bin zsh -c 'jq --version'
    [ "$status" -eq 0 ]
    [ "$output" = jq-1.7.1 ]
  fi
}

@test "shims come first in a login shell even when PATH already has them late" {
  cd "$HOME"
  run env -i HOME="$HOME" PATH="/usr/bin:/bin:$HOME/.local/share/mise/shims" bash -lc 'command -v jq'
  [ "$output" = "$HOME/.local/share/mise/shims/jq" ]
}

@test "a second apply changes nothing and adds no backup" {
  local before after backups_before backups_after
  before=$(home_fingerprint)
  backups_before=$(ls "$HOME/.local/state/povy/backups")
  run povy apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 written"* ]]
  after=$(home_fingerprint)
  backups_after=$(ls "$HOME/.local/state/povy/backups")
  [ "$before" = "$after" ]
  [ "$backups_before" = "$backups_after" ]
}

@test "the Git identity comes from config.toml" {
  cd "$HOME"
  [ "$(git config --global --includes --get user.email)" = test@example.org ]
  [ "$(git config --global --includes --get user.name)" = "Test User" ]
}

@test "on macOS, apply sets the GUI PATH through the stub, never the real launchctl" {
  [ -s "$BATS_FILE_TMPDIR/launchctl/calls" ] || [ "$(uname -s)" != Darwin ]
}

@test "the secret never appears in the output" {
  ! grep -qF 's3cret' "$BATS_FILE_TMPDIR/apply.log"
}

@test "no staging directory with rendered secrets is left behind" {
  [ -z "$(find "$HOME/.local/state/povy" -maxdepth 1 -name 'staging.*')" ]
}

@test "the real home is untouched" {
  HOME=$REAL_HOME real_home_snapshot >"$BATS_FILE_TMPDIR/real-after"
  cmp "$BATS_FILE_TMPDIR/real-before" "$BATS_FILE_TMPDIR/real-after"
}
