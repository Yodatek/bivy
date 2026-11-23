#!/usr/bin/env bats
# The profile's commands, [_.povy] bin, with the example profile's
# bin/example-hello, and the shell code a profile writes into the rc files.

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

@test "the profile commands run from zsh -c, bash -lc and shells started with an empty environment" {
  local shell_cmd
  for shell_cmd in 'bash -lc' 'zsh -c' 'zsh -lc'; do
    command -v "${shell_cmd%% *}" >/dev/null || continue
    # shellcheck disable=SC2086 # The shell and its flags.
    run $shell_cmd 'example-hello'
    [ "$output" = "hello from the example profile" ] || {
      echo "not from $shell_cmd: $output"
      return 1
    }
    # shellcheck disable=SC2086
    run env -i HOME="$HOME" PATH=/usr/bin:/bin $shell_cmd 'example-hello'
    [ "$output" = "hello from the example profile" ] || {
      echo "not from env -i $shell_cmd: $output"
      return 1
    }
  done
}

@test "the PowerShell parts of the profile are left to the Windows engine" {
  run grep -rlF example.ps1 "$HOME/.config/povy" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zshenv"
  [ -z "$output" ]
}

@test "doctor checks that the profile commands are on PATH" {
  # The seed's mise config includes the seed's clone: apply points it at this one.
  povy apply
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   profile commands on PATH: ~/.local/state/povy/profile/bin"* ]] || false
  sed -i.bak '/\/profile\/bin"*$/d' "$HOME/.config/povy/env.sh"
  run povy doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] the profile commands in ~/.local/state/povy/profile/bin are not on PATH; run: povy apply"* ]] || false
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

@test "invalid bin values are refused: outside the profile, absolute, missing, not a directory" {
  local profile=$BATS_TEST_TMPDIR/bad config=$BATS_TEST_TMPDIR/c.toml case value expected
  make_mise_profile "$profile" "" '[_.povy]' 'files/t=x'
  ln -s "$BATS_TEST_TMPDIR" "$profile/escape"
  commit_all "$profile"
  write_config "$config" "$profile"
  for case in '../outside|invalid _.povy.bin: ../outside' '/usr/bin|invalid _.povy.bin: /usr/bin' \
    '~/bin|invalid _.povy.bin: ~/bin' 'a/./b|invalid _.povy.bin: a/./b' \
    'missing|_.povy.bin is not a directory of the profile: missing' \
    'files/t|_.povy.bin is not a directory of the profile: files/t' \
    'escape|_.povy.bin is outside the profile: escape'; do
    value=${case%%|*}
    expected=${case#*|}
    printf '[_.povy]\nbin = "%s"\n' "$value" >"$profile/mise.toml"
    commit_all "$profile"
    run povy init --config "$config"
    [ "$status" -ne 0 ] || {
      echo "accepted: bin = $value"
      return 1
    }
    [[ "$output" == *"$expected"* ]] || {
      echo "unexpected message for bin = $value: $output"
      return 1
    }
  done
}

@test "a profile's block in the rc files gives interactive shells its functions, and a second apply changes nothing" {
  local profile=$BATS_TEST_TMPDIR/profile file before
  make_mise_profile "$profile" "" "$(for file in .zshrc .bashrc; do
    printf '[bootstrap.files."~/%s"]\nos = "unix"\nid = "team"\ntemplate = true\n' "$file"
    printf "block = '''\n. \"{{ config_root }}/shell/functions.sh\"\n'''\n\n"
  done)" 'shell/functions.sh=team_greet() { echo "hello, $1"; }'
  write_config "$BATS_TEST_TMPDIR/c.toml" "$profile"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  povy apply
  grep -qF '# >>> mise:team >>>' "$HOME/.bashrc"
  [ "$(tail -n 1 "$HOME/.bashrc")" = '# <<< povy interactive <<<' ]
  [ "$(tail -n 1 "$HOME/.zshrc")" = '# <<< povy <<<' ]
  run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb bash -i -c 'team_greet ada'
  [[ "$output" == *"hello, ada"* ]] || false
  if command -v zsh >/dev/null; then
    run env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb zsh -i -c 'team_greet ada'
    [[ "$output" == *"hello, ada"* ]] || false
  fi

  before=$(home_fingerprint)
  run povy apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Applied: 0 written"* ]] || false
  [ "$before" = "$(home_fingerprint)" ]
}
