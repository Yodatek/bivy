#!/usr/bin/env bats
# _samples/profile stays a valid profile, read the way its README says. It is never
# applied here: mise bootstrap would install its packages on this machine.

load helper

setup() {
  sandbox_setup
  SAMPLE=$POVY_ROOT/_samples/profile
}

@test "init reads the sample profile from a directory of its repository and seeds its secret" {
  local repo=$BATS_TEST_TMPDIR/repo config=$BATS_TEST_TMPDIR/config.toml
  mkdir -p "$repo/_samples"
  cp -R "$SAMPLE" "$repo/_samples/profile"
  commit_all "$repo"
  write_config "$config" "$repo"
  printf 'profile_path = "_samples/profile"\n' >>"$config"
  run povy init --config "$config"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fill these secrets"*SAMPLE_API_TOKEN* ]] || false
  grep -qxF 'SAMPLE_API_TOKEN=' "$HOME/.config/povy/.env"
  # init changes nothing outside povy's own directories.
  [ ! -e "$HOME/.config/mise/conf.d/povy.toml" ]
  [ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.bashrc" ]

  load_libs
  yq_ensure
  config_load
  profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  [ "$PROFILE_TEAM" = "$POVY_PROFILE_DIR/_samples/profile/team.toml" ]
  [ "$PROFILE_PROJECT" = "$POVY_PROFILE_DIR/_samples/profile/mise.toml" ]
  [ "$PROFILE_BIN" = "$POVY_PROFILE_DIR/_samples/profile/bin" ]
  [ -x "$PROFILE_BIN/sample-hello" ]
}

@test "mise reads the sample's mise.toml, and every file it names is in the profile" {
  local copy=$BATS_TEST_TMPDIR/sample status_json source
  cp -R "$SAMPLE" "$copy"
  load_libs
  yq_ensure
  mise_run trust --quiet "$copy/mise.toml"
  status_json=$(mise_run bootstrap status --json -C "$copy")
  [ "$(printf '%s' "$status_json" | "$POVY_YQ" -p json '[.secrets[].env] | join(" ")')" = SAMPLE_API_TOKEN ]
  while IFS= read -r source; do
    [ -n "$source" ] && [ "$source" != null ] || continue
    [ -f "$source" ] || {
      echo "missing: $source"
      return 1
    }
  done <<<"$(printf '%s' "$status_json" | "$POVY_YQ" -p json '.files[].origin.source')"
  [ -n "$(printf '%s' "$status_json" | "$POVY_YQ" -p json '.files[].id.name | select(. == "*/sample.conf")')" ]
}

@test "the sample's team.toml is valid TOML that mise can include" {
  load_libs
  yq_ensure
  toml_query "$SAMPLE/team.toml" '.tools | keys' >/dev/null
  [ "$(toml_query "$SAMPLE/team.toml" '.tools.jq')" = 1.7.1 ]
}

@test "the sample's [_.povy.windows] lists files that mise.toml declares and shell files that exist" {
  load_libs
  yq_ensure
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ "$(toml_query "$SAMPLE/mise.toml" ".bootstrap.files[\"$file\"] | tag")" = '!!map' ] || {
      echo "not in [bootstrap.files]: $file"
      return 1
    }
  done <<<"$(toml_query "$SAMPLE/mise.toml" '._.povy.windows.files[]')"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$SAMPLE/$file" ] || {
      echo "missing: $file"
      return 1
    }
  done <<<"$(toml_query "$SAMPLE/mise.toml" '._.povy.windows.shell[]')"
}

@test "the sample shell file parses in bash and zsh" {
  local file=$SAMPLE/shell/functions.sh
  bash -n "$file"
  command -v zsh >/dev/null || skip "zsh is not installed"
  zsh -n "$file"
}
