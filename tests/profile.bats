#!/usr/bin/env bats
# Profiles: the clone and its ref, team.toml and mise.toml, and the secrets that
# reach mise bootstrap.

load helper

setup() {
  sandbox_setup
  CONFIG=$BATS_TEST_TMPDIR/config.toml
  PROFILE=$BATS_TEST_TMPDIR/profile
  CLONE=$HOME/.local/state/povy/profile
  ENV_FILE=$HOME/.config/povy/.env
}

# Runs init with the profile, then fills the secrets given as KEY=VALUE.
prepare() {
  local pair
  write_config "$CONFIG" "$PROFILE"
  povy init --config "$CONFIG"
  for pair in "$@"; do
    printf '%s\n' "$pair" >>"$ENV_FILE"
  done
}

# Commits a profile whose template reads one secret: init names it, which tells
# which commit of the profile it read.
commit_secret() {
  out_file_project "$1" >"$PROFILE/mise.toml"
  mkdir -p "$PROFILE/files"
  printf '{{ secret(name="%s") }}\n' "$1" >"$PROFILE/files/t"
  commit_all "$PROFILE"
}

init_with_ref() {
  write_config "$CONFIG" "$PROFILE"
  [ -z "$1" ] || printf 'profile_ref = "%s"\n' "$1" >>"$CONFIG"
  run povy init --config "$CONFIG"
  echo "$output"
}

# mise reports only the secrets that a template reads, so each test's template
# reads all of them.
@test "init seeds .env with the secrets mise.toml declares, and keeps the lines already there" {
  make_mise_profile "$PROFILE" "" "$(out_file_project FIRST SECOND)" \
    'files/t={{ secret(name="FIRST") }} {{ secret(name="SECOND") }}'
  mkdir -p "${ENV_FILE%/*}"
  printf 'OTHER=1\nSECOND=kept' >"$ENV_FILE"
  write_config "$CONFIG" "$PROFILE"
  run povy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fill these secrets"*FIRST* ]] || false
  [[ "$output" != *SECOND* ]] || false
  grep -qxF 'FIRST=' "$ENV_FILE"
  grep -qxF 'SECOND=kept' "$ENV_FILE"
  grep -qxF 'OTHER=1' "$ENV_FILE"
  [ "$(grep -c '^SECOND=' "$ENV_FILE")" -eq 1 ]
  [ "$(file_mode "$ENV_FILE")" = 600 ]
  cp "$ENV_FILE" "$BATS_TEST_TMPDIR/env.before"
  povy init --config "$CONFIG"
  cmp "$BATS_TEST_TMPDIR/env.before" "$ENV_FILE"
}

@test "apply stops on an empty secret, names it and writes nothing in the home" {
  make_mise_profile "$PROFILE" "" "$(out_file_project NEEDED)" 'files/t={{ secret(name="NEEDED") }}'
  prepare
  local before
  before=$(home_fingerprint)
  run povy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *NEEDED*"secrets above are empty"* ]] || false
  [ ! -e "$HOME/.out/t" ]
  [ ! -e "$HOME/.zshenv" ]
  [ ! -e "$HOME/.bashrc" ]
  [ ! -e "$HOME/.gitconfig" ]
  [ ! -e "$HOME/.config/mise/conf.d/povy.toml" ]
  [ "$before" = "$(home_fingerprint)" ]
}

@test "a secret set in the environment instead of .env works too" {
  make_mise_profile "$PROFILE" "" "$(out_file_project NEEDED)" 'files/t={{ secret(name="NEEDED") }}'
  prepare
  NEEDED=from-env run povy apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = from-env ]
}

@test "secrets reach mise in its environment, never on its command line" {
  local real wrap=$BATS_TEST_TMPDIR/wrap
  real=$(command -v mise)
  mkdir -p "$wrap"
  # A mise in front of the real one that records its arguments.
  cat >"$wrap/mise" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/mise.args"
exec "$real" "\$@"
SH
  chmod +x "$wrap/mise"
  make_mise_profile "$PROFILE" "" "$(out_file_project TOKEN)" 'files/t={{ secret(name="TOKEN") }}'
  prepare 'TOKEN=not-an-argument'
  PATH="$wrap:$PATH" run povy apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = not-an-argument ]
  grep -qF "bootstrap --yes -C $CLONE" "$BATS_TEST_TMPDIR/mise.args"
  ! grep -qF not-an-argument "$BATS_TEST_TMPDIR/mise.args" || false
  [[ "$output" != *not-an-argument* ]] || false
}

@test "secret values with special characters reach the file verbatim" {
  make_mise_profile "$PROFILE" "" "$(out_file_project S)" 'files/t=[{{ secret(name="S") }}]'
  prepare 'S=a&b\c/d$e`f {{name}} "q"'
  run povy apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = '[a&b\c/d$e`f {{name}} "q"]' ]
}

@test ".env values: quotes removed, export accepted, CRLF tolerated, last line wins, never executed" {
  make_mise_profile "$PROFILE" "" "$(out_file_project A B C D)" \
    'files/t={{ secret(name="A") }}|{{ secret(name="B") }}|{{ secret(name="C") }}|{{ secret(name="D") }}'
  prepare
  {
    printf 'export A="one two"\n'
    printf "B='three'\n"
    printf 'C=four\r\n'
    printf 'D=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR"
  } >>"$ENV_FILE"
  run povy apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = "one two|three|four|\$(touch $BATS_TEST_TMPDIR/pwned)" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

# The clone itself is left out: the update brings the broken template.
outside_clone_fingerprint() {
  home_fingerprint | grep -vF './.local/state/povy/profile/'
}

@test "a template that mise cannot render stops apply before anything changes in the home" {
  make_mise_profile "$PROFILE" "" "$(out_file_project)" 'files/t=one'
  prepare
  povy apply
  echo '{{ nope }}' >"$PROFILE/files/t"
  commit_all "$PROFILE"
  local before
  before=$(outside_clone_fingerprint)
  run povy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"mise cannot read the profile"* ]] || false
  [ "$(cat "$HOME/.out/t")" = one ]
  [ "$before" = "$(outside_clone_fingerprint)" ]
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mise cannot read the profile"* ]] || false
}

@test "a repository with neither team.toml nor mise.toml is refused" {
  make_mise_profile "$PROFILE" "" "" 'README=nothing here'
  write_config "$CONFIG" "$PROFILE"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the profile has neither team.toml nor mise.toml: $PROFILE"* ]] || false
}

@test "a povy 0.1 profile, with only profile.toml, is refused with the way to convert it" {
  make_mise_profile "$PROFILE" "" "" 'profile.toml=[tools]
jq = "1.7.1"'
  write_config "$CONFIG" "$PROFILE"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the profile is in the povy 0.1 format, profile.toml; convert it to team.toml and mise.toml"* ]] || false
  # init installed config.toml before it read the profile: apply refuses it too.
  run povy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"povy 0.1 format"* ]] || false
  [ ! -e "$HOME/.config/mise/conf.d/povy.toml" ]
}

@test "team.toml and mise.toml must be regular files" {
  echo '[env]' >"$BATS_TEST_TMPDIR/outside.toml"
  mkdir -p "$PROFILE"
  ln -s "$BATS_TEST_TMPDIR/outside.toml" "$PROFILE/team.toml"
  commit_all "$PROFILE"
  write_config "$CONFIG" "$PROFILE"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the profile's team.toml must be a regular file"* ]] || false

  rm -rf "$PROFILE" "$CLONE"
  make_mise_profile "$PROFILE" '[env]' "" 'mise.toml/keep=x'
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the profile's mise.toml must be a regular file"* ]] || false
}

# Runs init on a profile whose mise.toml is the body given, which must stop it with
# the message given.
refused_project() {
  rm -rf "$PROFILE" "$CLONE"
  make_mise_profile "$PROFILE" "" "$1"
  write_config "$CONFIG" "$PROFILE"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ] && [[ "$output" == *"$2"* ]] || {
    printf 'not refused with "%s":\n%s\n---\n%s\n' "$2" "$1" "$output"
    return 1
  }
}

@test "invalid mise.toml content is refused" {
  refused_project '[_.povy' 'mise.toml is not valid TOML'
  refused_project $'[_]\npovy = "bin"' '_.povy must be a table: [_.povy]'
  refused_project $'[_.povy]\nbin = 3' '_.povy.bin must be a string'
  refused_project $'[bootstrap.secrets]\nx = { env = "bad-name" }' "mise cannot read the profile"
}

@test "a new profile commit is picked up, an unreachable remote is not fatal" {
  make_mise_profile "$PROFILE" "" "$(out_file_project)" 'files/t=one'
  prepare
  povy apply
  [ "$(cat "$HOME/.out/t")" = one ]
  # Without team.toml, the mise config includes nothing.
  ! grep -q '^include' "$HOME/.config/mise/conf.d/povy.toml" || false

  echo two >"$PROFILE/files/t"
  commit_all "$PROFILE"
  povy apply
  [ "$(cat "$HOME/.out/t")" = two ]

  mv "$PROFILE" "$PROFILE.gone"
  run povy apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"using the local copy"* ]] || false
}

@test "after a commit that breaks team.toml, the next apply takes the fix" {
  make_mise_profile "$PROFILE" '[env]
TEAM = "v1"' ""
  prepare
  povy apply
  printf '[env\nTEAM = "v2"\n' >"$PROFILE/team.toml"
  commit_all "$PROFILE"
  run povy apply
  [ "$status" -ne 0 ]
  printf '[env]\nTEAM = "v3"\n' >"$PROFILE/team.toml"
  commit_all "$PROFILE"
  run povy apply
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qxF 'TEAM = "v3"' "$CLONE/team.toml"
}

@test "changing the profile URL replaces the clone" {
  make_mise_profile "$PROFILE" "" "$(out_file_project)" 'files/t=one'
  make_mise_profile "$PROFILE.2" "" "$(out_file_project)" 'files/t=two'
  prepare
  write_config "$CONFIG" "$PROFILE.2"
  povy init --config "$CONFIG"
  povy apply
  [ "$(cat "$HOME/.out/t")" = two ]
  [ "$(git -C "$CLONE" remote get-url origin)" = "$PROFILE.2" ]
}

@test "a profile at a URL comes without the content of its history, one at a path whole" {
  local old
  # A file that only the history holds.
  make_mise_profile "$PROFILE" '[env]
TEAM = "v1"' "" 'heavy=old content'
  old=$(git -C "$PROFILE" rev-parse HEAD:heavy)
  git -C "$PROFILE" rm --quiet heavy
  commit_all "$PROFILE"
  # Git servers let clients filter what they fetch; a local repository, when told to.
  git -C "$PROFILE" config uploadpack.allowFilter true

  write_config "$CONFIG" "file://$PROFILE"
  povy init --config "$CONFIG"
  [ "$(git -C "$CLONE" config remote.origin.partialclonefilter)" = blob:none ]
  git -C "$CLONE" rev-list --objects --missing=print --all | grep -qxF "?$old"
  grep -qxF 'TEAM = "v1"' "$CLONE/team.toml"

  write_config "$CONFIG" "$PROFILE"
  povy init --config "$CONFIG"
  run git -C "$CLONE" config remote.origin.partialclonefilter
  [ "$status" -ne 0 ]
  git -C "$CLONE" cat-file -e "$old"
}

@test "mise includes team.toml in every directory, and the user's own mise config wins" {
  make_mise_profile "$PROFILE" '[env]
POVY_LEVEL = "team"
POVY_TEAM_ONLY = "team"' ""
  mkdir -p "$HOME/.config/mise"
  printf '[env]\nPOVY_LEVEL = "mine"\n' >"$HOME/.config/mise/config.toml"
  cp "$HOME/.config/mise/config.toml" "$BATS_TEST_TMPDIR/mine.before"
  prepare
  povy apply
  cmp "$BATS_TEST_TMPDIR/mine.before" "$HOME/.config/mise/config.toml"
  grep -qxF "include = [\"$CLONE/team.toml\"]" "$HOME/.config/mise/conf.d/povy.toml"
  grep -qxF '"yq" = "4"' "$HOME/.config/mise/conf.d/povy.toml"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run mise env --json
  [[ "$output" == *'"POVY_TEAM_ONLY": "team"'* ]] || false
  [[ "$output" == *'"POVY_LEVEL": "mine"'* ]] || false
}

@test "apply works from a directory with an untrusted mise.toml" {
  write_config "$CONFIG"
  povy init --config "$CONFIG"
  mkdir "$BATS_TEST_TMPDIR/project"
  printf '[tools]\njq = "1.6"\n' >"$BATS_TEST_TMPDIR/project/mise.toml"
  cd "$BATS_TEST_TMPDIR/project"
  run povy apply
  [ "$status" -eq 0 ]
}

@test "profile_ref takes a branch, a tag or a commit; another ref, or none, gives a new clone" {
  local commit
  make_mise_profile "$PROFILE" "" ""  'README=refs'
  commit_secret COMMIT_SECRET
  commit=$(git -C "$PROFILE" rev-parse HEAD)
  commit_secret TAG_SECRET
  git -C "$PROFILE" tag v1
  commit_secret MAIN_SECRET
  git -C "$PROFILE" switch --quiet -c alt
  commit_secret ALT_SECRET
  git -C "$PROFILE" switch --quiet main

  init_with_ref alt
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned profile $PROFILE, ref alt"* ]] || false
  [[ "$output" == *ALT_SECRET* ]] || false
  [ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = alt ]

  # The same ref keeps the clone.
  touch "$CLONE/.marker"
  init_with_ref alt
  [ "$status" -eq 0 ]
  [[ "$output" != *"cloned profile"* ]] || false
  [ -e "$CLONE/.marker" ]

  init_with_ref v1
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned profile $PROFILE, ref v1"* ]] || false
  [[ "$output" == *TAG_SECRET* && "$output" != *ALT_SECRET* ]] || false
  [ ! -e "$CLONE/.marker" ]
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$PROFILE" rev-parse 'v1^{commit}')" ]

  init_with_ref "$commit"
  [ "$status" -eq 0 ]
  [[ "$output" == *COMMIT_SECRET* && "$output" != *TAG_SECRET* ]] || false
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$commit" ]

  init_with_ref ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned profile $PROFILE"* ]] || false
  [[ "$output" == *MAIN_SECRET* && "$output" != *COMMIT_SECRET* ]] || false
  [ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = main ]
}

@test "on each update, a branch follows its remote, a tag is looked up again, a commit stays" {
  local commit
  make_mise_profile "$PROFILE" "" "" 'README=refs'
  commit_secret ONE
  commit=$(git -C "$PROFILE" rev-parse HEAD)
  git -C "$PROFILE" tag v1

  init_with_ref main
  commit_secret TWO
  init_with_ref main
  [[ "$output" == *TWO* ]] || false
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$PROFILE" rev-parse main)" ]

  init_with_ref v1
  [[ "$output" == *ONE* ]] || false
  commit_secret THREE
  git -C "$PROFILE" tag --force v1 >/dev/null
  init_with_ref v1
  [[ "$output" == *THREE* ]] || false
  [[ "$output" != *"cloned profile"* ]] || false
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$PROFILE" rev-parse main)" ]

  init_with_ref "$commit"
  commit_secret FOUR
  init_with_ref "$commit"
  [[ "$output" == *ONE* && "$output" != *FOUR* ]] || false
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$commit" ]
}

@test "profile_branch is the old name of profile_ref; setting both is refused" {
  make_mise_profile "$PROFILE" "" "" 'README=refs'
  commit_secret MAIN_SECRET
  git -C "$PROFILE" switch --quiet -c alt
  commit_secret ALT_SECRET
  git -C "$PROFILE" switch --quiet main

  write_config "$CONFIG" "$PROFILE"
  printf 'profile_branch = "alt"\n' >>"$CONFIG"
  run povy init --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned profile $PROFILE, ref alt"* ]] || false
  [[ "$output" == *ALT_SECRET* ]] || false
  [ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = alt ]
  run povy doctor
  [[ "$output" == *"[ok]   profile $PROFILE, ref alt"* ]] || false

  printf 'profile_ref = "alt"\n' >>"$CONFIG"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"set profile_ref only, profile_branch is its old name"* ]] || false
}

@test "a profile_ref that does not exist stops init" {
  make_mise_profile "$PROFILE" '[env]' ""
  init_with_ref nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not clone the profile: $PROFILE, ref nope"* ]] || false
  [ ! -e "$CLONE" ]
}

@test "invalid profile_ref and profile_branch values are refused" {
  local key value
  for key in profile_ref profile_branch; do
    for value in '"-x"' '"a b"' '"a..b"' '"/abs"' '3'; do
      write_config "$CONFIG" "$PROFILE"
      printf '%s = %s\n' "$key" "$value" >>"$CONFIG"
      run povy init --config "$CONFIG"
      [ "$status" -ne 0 ] || {
        echo "accepted: $key = $value"
        return 1
      }
      [[ "$output" == *"$key must be a string"* || "$output" == *"invalid $key: "* ]] || false
    done
  done
  write_config "$CONFIG"
  printf 'profile_ref = "main"\n' >>"$CONFIG"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile_ref needs a profile"* ]] || false
}

@test "profile_path reads the profile from a directory of its repository" {
  mkdir -p "$PROFILE/nested"
  cp -R "$POVY_ROOT/tests/fixtures/profile" "$PROFILE/nested/profile"
  commit_all "$PROFILE"
  write_config "$CONFIG" "$PROFILE"
  printf 'profile_path = "nested/profile/"\n' >>"$CONFIG"
  povy init --config "$CONFIG"
  echo 'EXAMPLE_API_TOKEN=x' >>"$ENV_FILE"
  run povy apply
  [ "$status" -eq 0 ]
  grep -qxF 'token = x' "$HOME/.config/povy-example/example.conf"
  grep -qxF "include = [\"$CLONE/nested/profile/team.toml\"]" "$HOME/.config/mise/conf.d/povy.toml"
  run env -i HOME="$HOME" PATH=/usr/bin:/bin bash -lc 'example-hello'
  [ "$output" = "hello from the example profile" ]
  run povy doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   profile $PROFILE, path nested/profile"* ]] || false
  [[ "$output" == *"[ok]   profile commands on PATH: ~/.local/state/povy/profile/nested/profile/bin"* ]] || false
}

@test "invalid profile_path values are refused" {
  local value
  make_mise_profile "$PROFILE" '[env]' "" 'empty/.keep='
  ln -s "$BATS_TEST_TMPDIR" "$PROFILE/escape"
  commit_all "$PROFILE"
  for value in '"../outside"' '"/abs"' '"a/../b"' '3' '"missing"' '"escape"' '"empty"'; do
    write_config "$CONFIG" "$PROFILE"
    printf 'profile_path = %s\n' "$value" >>"$CONFIG"
    run povy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $value"
      return 1
    }
  done
  write_config "$CONFIG"
  printf 'profile_path = "x"\n' >>"$CONFIG"
  run povy init --config "$CONFIG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile_path needs a profile"* ]] || false
}

@test "a file that mise bootstrap replaces is backed up first, with what it held" {
  local found
  make_mise_profile "$PROFILE" "" "$(out_file_project)" 'files/t=team'
  prepare
  mkdir -p "$HOME/.out"
  printf 'mine\n' >"$HOME/.out/t"
  run povy apply
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.out/t")" = team ]
  found=$(find "$HOME/.local/state/povy/backups" -path '*/.out/t')
  [ "$(cat "$found")" = mine ]
  run povy apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"backed up $HOME/.out/t"* ]] || false
}
