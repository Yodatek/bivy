#!/usr/bin/env bats
# _samples/profile stays a valid profile, read the way its README says.

load helper

setup() {
  sandbox_setup
}

@test "the sample profile is valid and uses every key" {
  local repo=$BATS_TEST_TMPDIR/repo config=$BATS_TEST_TMPDIR/config.toml source target
  mkdir -p "$repo/_samples"
  cp -R "$POVY_ROOT/_samples/profile" "$repo/_samples/profile"
  commit_all "$repo"
  write_config "$config" "$repo"
  printf 'profile_path = "_samples/profile"\n' >>"$config"
  run povy init --config "$config"
  [ "$status" -eq 0 ]
  grep -qx 'SAMPLE_API_TOKEN=' "$HOME/.config/povy/.env"

  load_libs
  yq_ensure
  config_load
  profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  [ "$PROFILE_PROMPT" = starship ]
  [ -x "$POVY_PROFILE_ROOT/$PROFILE_BIN/sample-hello" ]
  [ -n "$PROFILE_SHELL" ] && [ -n "$PROFILE_SECRETS" ] && [ -n "$PROFILE_PACKAGES" ]
  [[ "$PROFILE_TOOLS" == *$'node\t22 20'* ]]
  [[ "$PROFILE_TOOLS" == *$'npm:prettier\t3'* ]]
  # Every template renders: none has an unknown placeholder.
  while IFS=$'\t' read -r source target; do
    [ -n "$source" ] || continue
    template_render "$POVY_PROFILE_ROOT/$source" "$BATS_TEST_TMPDIR/rendered"
  done <<<"$PROFILE_FILES"
  [ "$(printf '%s' "$PROFILE_FILES" | grep -c .)" -eq 2 ]
}

@test "the sample shell file parses in bash and zsh" {
  local file=$POVY_ROOT/_samples/profile/shell/aliases.sh
  bash -n "$file"
  command -v zsh >/dev/null || skip "zsh is not installed"
  zsh -n "$file"
}
