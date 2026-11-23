#!/usr/bin/env bats
# Profile commands (bin) and interactive shell files (shell), with the example
# profile: bin/example-hello and shell/example.sh.

load helper

setup_file() {
  export REAL_HOME=$HOME
  sandbox_env "$BATS_FILE_TMPDIR/seed"
  export MISE_DATA_DIR="$BATS_SUITE_TMPDIR/mise-data"
  export MISE_CACHE_DIR="$BATS_SUITE_TMPDIR/mise-cache"
  make_profile_repo "$BATS_FILE_TMPDIR/profile"
  write_config "$BATS_FILE_TMPDIR/config.toml" "$BATS_FILE_TMPDIR/profile"
  povy init --config "$BATS_FILE_TMPDIR/config.toml"
  echo 'EXAMPLE_API_TOKEN=x' >>"$HOME/.config/povy/.env"
  povy apply
}

setup() {
  sandbox_setup
  cp -Rp "$BATS_FILE_TMPDIR/seed/." "$HOME/"
  cd "$HOME"
}

@test "the profile commands run from login and non-interactive shells" {
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -lc 'example-hello'
  [ "$output" = "hello from the example profile" ]
  command -v zsh >/dev/null || skip "zsh is not installed"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin zsh -c 'example-hello'
  [ "$output" = "hello from the example profile" ]
}

@test "interactive zsh and bash get the aliases and functions of the profile" {
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb bash -i -c 'example_greet ada; example-alias'
  [[ "$output" == *"hello, ada"*"alias from the example profile"* ]]
  command -v zsh >/dev/null || skip "zsh is not installed"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb zsh -i -c 'example_greet ada; example-alias'
  [[ "$output" == *"hello, ada"*"alias from the example profile"* ]]
}

@test "PowerShell files of the profile are left to povy on Windows" {
  grep -q 'shell/example.sh' "$HOME/.config/povy/interactive.sh"
  ! grep -q 'example.ps1' "$HOME/.config/povy/interactive.sh"
}

@test "the shell files are sourced once, even when .bash_profile sources .bashrc" {
  local login
  login=$(find "$HOME" -maxdepth 1 \( -name .bash_profile -o -name .profile \) | head -n 1)
  printf '. "$HOME/.bashrc"\n' >>"$login"
  printf 'echo sourced\n' >>"$HOME/.local/state/povy/profile/shell/example.sh"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb bash -l -i -c true
  [ "$(printf '%s\n' "$output" | grep -c '^sourced$')" -eq 1 ]
}

@test "doctor checks that the profile commands are on PATH" {
  run povy doctor
  [[ "$output" == *"[ok]   profile commands on PATH: bin"* ]]
  sed -i.bak '/\/profile\/bin"*$/d' "$HOME/.config/povy/env.sh"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"profile commands in bin are not on PATH"* ]]
}

@test "a command added to the profile is there after the next apply, PATH unchanged" {
  local profile=$BATS_TEST_TMPDIR/profile
  make_profile_repo "$profile"
  write_config "$BATS_TEST_TMPDIR/c.toml" "$profile"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  povy apply
  cp "$HOME/.config/povy/env.sh" "$BATS_TEST_TMPDIR/env.before"
  printf '#!/bin/sh\necho new command\n' >"$profile/bin/new-command"
  chmod +x "$profile/bin/new-command"
  commit_all "$profile"
  povy apply
  cmp "$BATS_TEST_TMPDIR/env.before" "$HOME/.config/povy/env.sh"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -lc 'new-command'
  [ "$output" = "new command" ]
}

@test "invalid bin and shell values are refused" {
  local profile=$BATS_TEST_TMPDIR/bad body
  for body in 'bin = "../outside"' 'bin = "/usr/bin"' 'bin = "missing"' 'bin = "files/t"' \
    'shell = "files/t"' 'shell = ["missing.sh"]' 'shell = ["../outside.sh"]' 'shell = [3]'; do
    rm -rf "$profile" "$HOME/.local/state/povy/profile"
    make_custom_profile "$profile" "$body" "t=x"
    write_config "$BATS_TEST_TMPDIR/c.toml" "$profile"
    run povy init --config "$BATS_TEST_TMPDIR/c.toml"
    [ "$status" -ne 0 ] || {
      echo "accepted: $body"
      return 1
    }
  done
}
