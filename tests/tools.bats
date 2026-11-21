#!/usr/bin/env bats
# povy tools: where each tool is declared, and what mise runs.

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
  CONFIG=$BATS_TEST_TMPDIR/config.toml
  cp "$BATS_FILE_TMPDIR/config.toml" "$CONFIG"
  cd "$HOME"
}

# The row of one tool, with its columns squeezed to single spaces.
row() {
  printf '%s\n' "$output" | awk -v t="$1" '$1 == t' | tr -s ' '
}

@test "each tool shows the level that declares it and what mise runs" {
  run povy tools
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == TOOL*DECLARED*FROM*ACTIVE ]]
  [[ "$(row yq)" == "yq 4 povy 4."* ]]
  [ "$(row jq)" = "jq 1.7.1 profile 1.7.1" ]
  [[ "$output" == *"into ~/.config/mise/conf.d/povy.toml"* ]]
}

@test "a machine tool replaces the profile one" {
  printf '\n[tools]\njq = "1.7.1"\n' >>"$CONFIG"
  povy init --config "$CONFIG"
  run povy tools
  echo "$output"
  [ "$(row jq)" = "jq 1.7.1 machine 1.7.1" ]
}

@test "a declaration not applied yet says so" {
  printf '\n[tools]\njq = "1.6"\nshellcheck = "0.11.0"\n' >>"$CONFIG"
  povy init --config "$CONFIG"
  run povy tools
  echo "$output"
  [ "$(row jq)" = "jq 1.6 machine 1.6 not applied; run: povy apply" ]
  [ "$(row shellcheck)" = "shellcheck 0.11.0 machine not applied; run: povy apply" ]
}

# jq 1.5: other tests install 1.6 in the mise data the suite shares.
@test "a version that is not installed says so" {
  printf '\n[tools]\njq = "1.5"\n' >>"$CONFIG"
  povy init --config "$CONFIG"
  sed -i.bak 's/^"jq" = .*/"jq" = "1.5"/' "$HOME/.config/mise/conf.d/povy.toml"
  run povy tools
  echo "$output"
  [ "$(row jq)" = "jq 1.5 machine 1.5 not installed; run: povy apply" ]
}

@test "the user's own mise config wins, and the table names it" {
  printf '[tools]\njq = "1.7.1"\nshellcheck = "0.11.0"\n' >"$HOME/.config/mise/config.toml"
  run povy tools
  echo "$output"
  [ "$(row jq)" = "jq 1.7.1 profile 1.7.1, set by ~/.config/mise/config.toml" ]
  [ "$(row shellcheck)" = "shellcheck 0.11.0 mise 0.11.0, set by ~/.config/mise/config.toml" ]
}
