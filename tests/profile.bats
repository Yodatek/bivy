#!/usr/bin/env bats

load helper

setup() {
  sandbox_setup
  CONFIG=$BATS_TEST_TMPDIR/config.toml
  PROFILE=$BATS_TEST_TMPDIR/profile
}

# Runs init with the profile, then fills the secret given as KEY=VALUE.
prepare() {
  write_config "$CONFIG" "$PROFILE"
  bivy init --config "$CONFIG"
  [ -z "${1:-}" ] || printf '%s\n' "$1" >>"$HOME/.config/bivy/.env"
}

FILE_ENTRY='[[files]]
source = "files/t"
target = ".out/t"'

@test "apply refuses empty secrets and writes nothing in the home" {
  make_custom_profile "$PROFILE" "[secrets]
required = [\"NEEDED\"]
$FILE_ENTRY" 't={{NEEDED}}'
  prepare
  run bivy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *NEEDED* ]]
  [ ! -e "$HOME/.out/t" ]
  [ ! -e "$HOME/.zshenv" ]
  [ ! -e "$HOME/.config/mise/conf.d/bivy.toml" ]
}

@test "an unknown placeholder stops apply before any file is written" {
  make_custom_profile "$PROFILE" "$FILE_ENTRY
[[files]]
source = \"files/bad\"
target = \".out/bad\"" 't=fine' 'bad={{NOPE}}'
  prepare
  run bivy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *NOPE* ]]
  [ ! -e "$HOME/.out/t" ]
  [ ! -e "$HOME/.zshenv" ]
}

@test "secret values with special characters are not reinterpreted" {
  make_custom_profile "$PROFILE" "[secrets]
required = [\"S\"]
$FILE_ENTRY" 't=[{{S}}] {{ not.a.placeholder }} {{name}}'
  prepare 'S=a&b\c/d$e`f {{name}}'
  run bivy apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = '[a&b\c/d$e`f {{name}}] {{ not.a.placeholder }} Test User' ]
}

@test ".env values: quotes removed, export accepted, CRLF tolerated, never executed" {
  make_custom_profile "$PROFILE" "[secrets]
required = [\"A\", \"B\", \"C\", \"D\"]
$FILE_ENTRY" 't={{A}}|{{B}}|{{C}}|{{D}}'
  prepare
  {
    printf 'export A="one two"\n'
    printf "B='three'\n"
    printf 'C=four\r\n'
    printf 'D=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR"
  } >>"$HOME/.config/bivy/.env"
  run bivy apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = "one two|three|four|\$(touch $BATS_TEST_TMPDIR/pwned)" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "targets outside the home are refused" {
  local target
  for target in '../escape' '/tmp/escape' 'a/../../escape' '~/escape' 'dir/'; do
    rm -rf "$PROFILE" "$HOME"
    mkdir -p "$HOME"
    make_custom_profile "$PROFILE" "[[files]]
source = \"files/t\"
target = \"$target\"" 't=x'
    write_config "$CONFIG" "$PROFILE"
    run bivy init --config "$CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *"home directory"* ]]
  done
}

@test "a template that is a symlink leaving the profile is refused" {
  echo private >"$BATS_TEST_TMPDIR/outside"
  mkdir -p "$PROFILE/files"
  ln -s "$BATS_TEST_TMPDIR/outside" "$PROFILE/files/link"
  printf '[[files]]\nsource = "files/link"\ntarget = ".x"\n' >"$PROFILE/profile.toml"
  commit_all "$PROFILE"
  write_config "$CONFIG" "$PROFILE"
  run bivy init --config "$CONFIG"
  [ "$status" -ne 0 ]
}

@test "invalid profile content is refused" {
  local body
  for body in \
    '[secrets]
required = ["bad-name"]' \
    '[tools]
"a b" = "1"' \
    '[[files]]
source = "files/absent"
target = ".x"' \
    '[[files]]
target = ".x"'; do
    rm -rf "$PROFILE"
    make_custom_profile "$PROFILE" "$body"
    write_config "$CONFIG" "$PROFILE"
    rm -rf "$HOME/.local/state/bivy/profile"
    run bivy init --config "$CONFIG"
    [ "$status" -ne 0 ]
  done
}

@test "a repository without profile.toml is refused" {
  mkdir -p "$PROFILE"
  echo x >"$PROFILE/README"
  commit_all "$PROFILE"
  write_config "$CONFIG" "$PROFILE"
  run bivy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *profile.toml* ]]
}

@test "a new profile commit is picked up, an unreachable remote is not fatal" {
  make_custom_profile "$PROFILE" "$FILE_ENTRY" 't=one'
  prepare
  bivy apply
  [ "$(cat "$HOME/.out/t")" = one ]

  echo two >"$PROFILE/files/t"
  commit_all "$PROFILE"
  bivy apply
  [ "$(cat "$HOME/.out/t")" = two ]
  [ -n "$(find "$HOME/.local/state/bivy/backups" -name t)" ]

  mv "$PROFILE" "$PROFILE.gone"
  run bivy apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"local copy"* ]]
}

@test "changing the profile URL replaces the clone" {
  make_custom_profile "$PROFILE" "$FILE_ENTRY" 't=one'
  make_custom_profile "$PROFILE.2" "$FILE_ENTRY" 't=two'
  prepare
  write_config "$CONFIG" "$PROFILE.2"
  bivy init --config "$CONFIG"
  bivy apply
  [ "$(cat "$HOME/.out/t")" = two ]
}

@test "a directory at the target is refused, not replaced" {
  make_custom_profile "$PROFILE" "$FILE_ENTRY" 't=x'
  prepare
  mkdir -p "$HOME/.out/t/keep"
  run bivy apply
  [ "$status" -ne 0 ]
  [ -d "$HOME/.out/t/keep" ]
}

@test "a symlink at the target is backed up as a link and replaced" {
  make_custom_profile "$PROFILE" "$FILE_ENTRY" 't=new'
  prepare
  mkdir -p "$HOME/.out"
  echo original >"$BATS_TEST_TMPDIR/link-target"
  ln -s "$BATS_TEST_TMPDIR/link-target" "$HOME/.out/t"
  run bivy apply
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.out/t" ]
  [ "$(cat "$HOME/.out/t")" = new ]
  [ "$(cat "$BATS_TEST_TMPDIR/link-target")" = original ]
  [ -L "$(find "$HOME/.local/state/bivy/backups" -name t)" ]
}

@test "machine tools override profile tools, and yq stays declared" {
  make_custom_profile "$PROFILE" '[tools]
jq = "1.7"'
  write_config "$CONFIG" "$PROFILE"
  printf '[tools]\njq = "1.7.1"\n' >>"$CONFIG"
  bivy init --config "$CONFIG"
  bivy apply
  grep -qxF '"jq" = "1.7.1"' "$HOME/.config/mise/conf.d/bivy.toml"
  grep -qxF '"yq" = "4"' "$HOME/.config/mise/conf.d/bivy.toml"
  [ "$(grep -c '"jq"' "$HOME/.config/mise/conf.d/bivy.toml")" -eq 1 ]
}

@test "a tool can list several versions, all installed, the first one by default" {
  make_custom_profile "$PROFILE" '[tools]
jq = ["1.7.1", "1.6"]'
  write_config "$CONFIG" "$PROFILE"
  bivy init --config "$CONFIG"
  bivy apply
  grep -qxF '"jq" = ["1.7.1", "1.6"]' "$HOME/.config/mise/conf.d/bivy.toml"
  cd "$HOME"
  [ "$(env -i HOME="$HOME" MISE_DATA_DIR="$MISE_DATA_DIR" PATH=/usr/bin:/bin bash -lc 'jq --version')" = jq-1.7.1 ]
  [ -x "$(mise where jq@1.6)/bin/jq" ] || [ -x "$(mise where jq@1.6)/jq" ]
}

@test "invalid version lists are refused" {
  local tools
  touch "$BATS_TEST_TMPDIR/1.7"
  cd "$BATS_TEST_TMPDIR"
  for tools in 'jq = []' 'jq = ["1.7.1", "bad version"]' 'jq = [["1.7.1"]]' 'jq = [{ v = "1" }]' 'jq = ["1.*"]'; do
    write_config "$CONFIG"
    printf '[tools]\n%s\n' "$tools" >>"$CONFIG"
    run bivy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $tools"
      return 1
    }
  done
}

@test "several tools keep each its own version" {
  make_custom_profile "$PROFILE" '[tools]
jq = "1.7.1"
"aqua:mikefarah/yq" = "4.54.1"'
  write_config "$CONFIG" "$PROFILE"
  bivy init --config "$CONFIG"
  load_libs
  yq_ensure
  config_load
  profile_load "$CFG_PROFILE"
  [ "$PROFILE_TOOLS" = $'jq\t1.7.1\naqua:mikefarah/yq\t4.54.1' ]
}

@test "several templates keep each their own target" {
  make_custom_profile "$PROFILE" '[[files]]
source = "files/a"
target = ".out/a"
[[files]]
source = "files/b"
target = ".out/with space/b"' 'a=first' 'b=second'
  prepare
  bivy apply
  [ "$(cat "$HOME/.out/a")" = first ]
  [ "$(cat "$HOME/.out/with space/b")" = second ]
}

@test "the user's own mise config is left alone" {
  write_config "$CONFIG"
  mkdir -p "$HOME/.config/mise"
  printf '[settings]\nexperimental = true\n' >"$HOME/.config/mise/config.toml"
  bivy init --config "$CONFIG"
  bivy apply
  [ "$(cat "$HOME/.config/mise/config.toml")" = $'[settings]\nexperimental = true' ]
}

@test "apply works from a directory with an untrusted mise.toml" {
  write_config "$CONFIG"
  bivy init --config "$CONFIG"
  mkdir "$BATS_TEST_TMPDIR/project"
  printf '[tools]\njq = "1.6"\n' >"$BATS_TEST_TMPDIR/project/mise.toml"
  cd "$BATS_TEST_TMPDIR/project"
  run bivy apply
  [ "$status" -eq 0 ]
}

@test "a profile branch is cloned; changing it or removing it gives a new clone" {
  make_custom_profile "$PROFILE" '[tools]
jq = "1.7.1"'
  git -C "$PROFILE" switch --quiet -c alt
  printf '[secrets]\nrequired = ["ALT_SECRET"]\n' >"$PROFILE/profile.toml"
  commit_all "$PROFILE"
  git -C "$PROFILE" switch --quiet main
  local clone=$HOME/.local/state/bivy/profile

  write_config "$CONFIG" "$PROFILE"
  printf 'profile_branch = "alt"\n' >>"$CONFIG"
  run bivy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALT_SECRET"* ]]
  [ "$(git -C "$clone" rev-parse --abbrev-ref HEAD)" = alt ]

  write_config "$CONFIG" "$PROFILE"
  run bivy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$(git -C "$clone" rev-parse --abbrev-ref HEAD)" = main ]
  [[ "$output" != *"ALT_SECRET"* ]]
}

@test "a profile branch that does not exist stops init" {
  make_custom_profile "$PROFILE" '[tools]
jq = "1.7.1"'
  write_config "$CONFIG" "$PROFILE"
  printf 'profile_branch = "nope"\n' >>"$CONFIG"
  run bivy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not clone the profile"*"branch nope"* ]]
}

@test "invalid profile_branch values are refused" {
  local value
  for value in '"-x"' '"a b"' '"a..b"' '3'; do
    write_config "$CONFIG" "$PROFILE"
    printf 'profile_branch = %s\n' "$value" >>"$CONFIG"
    run bivy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $value"
      return 1
    }
  done
  write_config "$CONFIG"
  printf 'profile_branch = "main"\n' >>"$CONFIG"
  run bivy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile_branch needs a profile"* ]]
}

@test "profile_path reads the profile from a directory of its repository" {
  mkdir -p "$PROFILE/nested"
  cp -R "$BIVY_ROOT/tests/fixtures/profile" "$PROFILE/nested/profile"
  commit_all "$PROFILE"
  write_config "$CONFIG" "$PROFILE"
  printf 'profile_path = "nested/profile/"\n' >>"$CONFIG"
  bivy init --config "$CONFIG"
  echo 'EXAMPLE_API_TOKEN=x' >>"$HOME/.config/bivy/.env"
  run bivy apply
  [ "$status" -eq 0 ]
  grep -qx 'token = x' "$HOME/.config/bivy-example/example.conf"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -lc 'example-hello'
  [ "$output" = "hello from the example profile" ]
  run bivy doctor
  [[ "$output" == *"[ok]   profile $PROFILE, path nested/profile"* ]]
  [[ "$output" == *"[ok]   profile commands on PATH: bin"* ]]
}

@test "invalid profile_path values are refused" {
  local value
  make_custom_profile "$PROFILE" '[tools]
jq = "1.7.1"'
  mkdir -p "$PROFILE/empty"
  touch "$PROFILE/empty/.keep"
  ln -s "$BATS_TEST_TMPDIR" "$PROFILE/escape"
  commit_all "$PROFILE"
  for value in '"../outside"' '"/abs"' '"a/../b"' '3' '"missing"' '"escape"' '"empty"'; do
    write_config "$CONFIG" "$PROFILE"
    printf 'profile_path = %s\n' "$value" >>"$CONFIG"
    run bivy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $value"
      return 1
    }
  done
  write_config "$CONFIG"
  printf 'profile_path = "x"\n' >>"$CONFIG"
  run bivy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile_path needs a profile"* ]]
}
