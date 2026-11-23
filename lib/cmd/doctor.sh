# shellcheck shell=bash
# povy doctor: reports the real state and changes nothing. Exits 0 when all checks
# pass, 1 when at least one fails. Warnings do not change the exit code.

DOCTOR_FAILED=0

doctor_ok() { printf '[ok]   %s\n' "$*"; }
doctor_warn() { printf '[warn] %s\n' "$*"; }
doctor_fail() {
  printf '[FAIL] %s\n' "$*"
  DOCTOR_FAILED=1
}

# Runs a command in a shell started from an almost empty environment, the way an
# IDE or an agent would: no ZDOTDIR, no mise on PATH. Only the startup files can
# put the shims on its PATH. It runs from HOME because mise shims refuse to run
# under a directory holding an untrusted mise.toml, which says nothing about this
# machine's setup.
doctor_probe() {
  local shell_cmd=$1 flags=$2 script=$3
  cd "$HOME" && env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin \
    ${MISE_DATA_DIR:+MISE_DATA_DIR="$MISE_DATA_DIR"} \
    ${MISE_CONFIG_DIR:+MISE_CONFIG_DIR="$MISE_CONFIG_DIR"} \
    ${XDG_CONFIG_HOME:+XDG_CONFIG_HOME="$XDG_CONFIG_HOME"} \
    ${XDG_DATA_HOME:+XDG_DATA_HOME="$XDG_DATA_HOME"} \
    "$shell_cmd" "$flags" "$script" </dev/null 2>/dev/null | tail -n 1
}

doctor_check_shell() {
  local shell_cmd=$1 flags=$2 label="$1 $2" resolved path from_mise=0
  command -v "$shell_cmd" >/dev/null 2>&1 || return 0
  resolved=$(doctor_probe "$shell_cmd" "$flags" 'command -v yq') || resolved=""
  # shellcheck disable=SC2016 # Expanded by the probed shell.
  path=$(doctor_probe "$shell_cmd" "$flags" 'printf "%s\n" "$PATH"') || path=""
  # mise activate puts its install directories first, and they hold the same tools.
  case $resolved in
    "$POVY_SHIMS_DIR/yq" | "$POVY_INSTALLS_DIR"/*) from_mise=1 ;;
  esac
  if [ "$from_mise" -eq 0 ]; then
    doctor_fail "shims not visible from a non-interactive '$label' (yq: ${resolved:-not found})"
  elif ! (doctor_probe "$shell_cmd" "$flags" 'yq --version') | grep -q version; then
    doctor_fail "the yq shim does not run from a non-interactive '$label'"
  elif [ "${path#*"$POVY_LOCAL_BIN"}" = "$path" ]; then
    doctor_fail "$(tilde_path "$POVY_LOCAL_BIN") is not on PATH in a non-interactive '$label'"
  else
    doctor_ok "shims and $(tilde_path "$POVY_LOCAL_BIN") visible from a non-interactive '$label'"
  fi
}

# A shim hidden by another directory runs a version that mise did not choose.
doctor_check_shadowed() {
  local shell_cmd=$1 flags=$2 commands=$3 path shadowed
  command -v "$shell_cmd" >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2016 # Expanded by the probed shell.
  path=$(doctor_probe "$shell_cmd" "$flags" 'printf "%s\n" "$PATH"') || return 0
  shadowed=$(shims_shadowed "$path" "$commands")
  [ -z "$shadowed" ] ||
    doctor_warn "in '$shell_cmd $flags', $(shims_shadowed_summary "$shadowed") before the mise shims"
}

doctor_check_mise() {
  local version
  if ! mise_find >/dev/null; then
    doctor_fail "mise is not installed"
    return 0
  fi
  version=$(mise_run --version 2>/dev/null | head -n 1) || version=""
  if [ -z "$version" ]; then
    doctor_fail "mise does not run: $(mise_find)"
  elif ! mise_recent_enough; then
    doctor_fail "mise $version is older than $POVY_MISE_MIN; update it with your package manager, or with: mise self-update"
  else
    doctor_ok "mise $version"
  fi
}

doctor_check_env_file() {
  local mode
  if [ ! -f "$POVY_ENV_FILE" ]; then
    doctor_fail "$POVY_ENV_FILE is missing; run: povy init"
    return 0
  fi
  mode=$(os_file_mode "$POVY_ENV_FILE")
  if [ "$mode" = 600 ]; then
    doctor_ok "$POVY_ENV_FILE has mode 600"
  else
    doctor_fail "$POVY_ENV_FILE has mode $mode, expected 600"
  fi
}

doctor_check_blocks() {
  local files file parts position name label
  files=$(shell_startup_files)
  while IFS=$'\t' read -r file parts position name; do
    [ -n "$file" ] || continue
    label="povy${name:+ $name} block"
    if [ -f "$file" ] && grep -qxF "$(block_start "$name")" "$file"; then
      doctor_ok "$label in $file"
    else
      doctor_fail "no $label in $file"
    fi
  done <<<"$files"
}

# Compares a generated file with what apply would write now.
doctor_check_generated() {
  local file=$1 expected=$2 label=$3
  if [ ! -f "$file" ]; then
    doctor_fail "$file is missing; run: povy apply"
  elif ! cmp -s "$expected" "$file"; then
    doctor_fail "$file is outdated; run: povy apply"
  else
    doctor_ok "$label"
  fi
}

doctor_check_gui() {
  local tmp file state
  file=$(os_gui_file)
  if ! tmp=$(mktemp "${TMPDIR:-/tmp}/povy-gui.XXXXXX"); then
    doctor_fail "cannot create a temporary file to check $file"
    return 0
  fi
  if os_gui_render "$tmp"; then
    doctor_check_generated "$file" "$tmp" "graphical apps get the shims at login: $file"
    os_gui_session_state && state=0 || state=$?
    case "$state" in
      0) doctor_ok "shims on the PATH of graphical apps" ;;
      1) doctor_warn "graphical apps started now do not see the shims; run povy apply, or log out and back in" ;;
    esac
  else
    doctor_warn "graphical apps: $POVY_SHIMS_DIR cannot be written safely in $file"
  fi
  rm -f "$tmp"
}

doctor_check_git() {
  local stage global file name count=0 stale=0 overriding
  if ! command -v git >/dev/null 2>&1; then
    doctor_fail "git is not installed"
    return 0
  fi
  global=$(git_global_file)
  if [ -f "$global" ] && grep -qxF "$POVY_BLOCK_START" "$global"; then
    doctor_ok "povy block in $global"
  else
    doctor_fail "no povy block in $global"
    return 0
  fi

  if ! stage=$(mktemp -d "${TMPDIR:-/tmp}/povy-git.XXXXXX"); then
    doctor_fail "cannot create a temporary directory to check $POVY_GIT_DIR"
    return 0
  fi
  if ! git_render "$stage"; then
    rm -rf "$stage"
    doctor_fail "could not generate the Git configuration"
    return 0
  fi
  for file in "$stage"/*; do
    name=${file##*/}
    if [ ! -f "$POVY_GIT_DIR/$name" ] || ! cmp -s "$file" "$POVY_GIT_DIR/$name"; then
      stale=1
    fi
    case "$name" in identity-*) count=$((count + 1)) ;; esac
  done
  for file in "$POVY_GIT_DIR"/identity-*; do
    [ ! -e "$file" ] || [ -e "$stage/${file##*/}" ] || stale=1
  done
  rm -rf "$stage"
  if [ "$stale" -ne 0 ]; then
    doctor_fail "$POVY_GIT_DIR does not match config.toml; run: povy apply"
    return 0
  fi
  doctor_ok "Git identity $CFG_EMAIL, and $count by directory"

  overriding=$(git_overriding_files)
  if [ -n "$overriding" ]; then
    doctor_warn "set after the povy include, user.name or user.email overrides it in: $(printf '%s' "$overriding" | tr '\n' ' ')"
  fi
}

# The profile, the mise config that includes it, its secrets, and whether mise
# bootstrap has applied all of its mise.toml.
doctor_check_profile() {
  local tmp names missing label
  if ! (profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH") 2>/dev/null; then
    doctor_fail "the profile is missing or invalid; run: povy apply"
    return 0
  fi
  profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  [ -z "$CFG_PROFILE" ] ||
    doctor_ok "profile $CFG_PROFILE${CFG_PROFILE_REF:+, ref $CFG_PROFILE_REF}${CFG_PROFILE_PATH:+, path $CFG_PROFILE_PATH}"

  if tmp=$(mktemp "${TMPDIR:-/tmp}/povy-mise.XXXXXX"); then
    team_conf_render >"$tmp"
    label="mise config: $(tilde_path "$POVY_MISE_CONF")"
    [ -z "$PROFILE_TEAM" ] || label="$label, which includes team.toml from the profile"
    doctor_check_generated "$POVY_MISE_CONF" "$tmp" "$label"
    rm -f "$tmp"
  fi
  if [ -n "$PROFILE_BIN" ]; then
    # shellcheck disable=SC2016 # Expanded by the probed shell.
    case ":$(doctor_probe bash -lc 'printf "%s\n" "$PATH"'):" in
      *":$PROFILE_BIN:"*) doctor_ok "profile commands on PATH: $(tilde_path "$PROFILE_BIN")" ;;
      *) doctor_fail "the profile commands in $(tilde_path "$PROFILE_BIN") are not on PATH; run: povy apply" ;;
    esac
  fi
  [ -n "$PROFILE_PROJECT" ] || return 0

  if ! names=$( (team_secret_names) 2>/dev/null); then
    doctor_fail "mise cannot read the profile's mise.toml; run: mise bootstrap status -C $POVY_PROFILE_ROOT"
    return 0
  fi
  missing=$(team_secrets_missing "$names")
  if [ -n "$missing" ]; then
    doctor_fail "empty secrets in $POVY_ENV_FILE: $(printf '%s' "$missing" | tr '\n' ' ')"
  elif [ -n "$names" ]; then
    doctor_ok "the secrets the profile needs are set"
  fi
  if team_mise_with_secrets "$names" bootstrap status --missing -C "$POVY_PROFILE_ROOT" >/dev/null 2>&1 </dev/null; then
    doctor_ok "mise bootstrap: the profile's mise.toml is applied"
  else
    doctor_fail "the profile's mise.toml is not fully applied; run: povy apply, or see: mise bootstrap status -C $POVY_PROFILE_ROOT"
  fi
}

cmd_doctor() {
  local commands
  [ $# -eq 0 ] || die "doctor takes no argument"

  povy_init_paths
  povy_load_os
  doctor_check_mise
  os_doctor

  if yq_resolve; then
    doctor_ok "$POVY_YQ_TOOL available"
  else
    doctor_fail "$POVY_YQ_TOOL is not installed; run: povy init"
  fi

  if [ ! -f "$POVY_CONFIG_FILE" ]; then
    doctor_fail "$POVY_CONFIG_FILE is missing; run: povy init"
  elif [ -z "$POVY_YQ" ]; then
    doctor_fail "$POVY_CONFIG_FILE cannot be read without yq"
  elif ! (config_load) 2>/dev/null; then
    doctor_fail "$POVY_CONFIG_FILE is invalid: $( (config_load) 2>&1 | sed -n 's/^error: //p' | head -n 1)"
  else
    doctor_ok "$POVY_CONFIG_FILE is valid"
    config_load
    doctor_check_profile
    doctor_check_git
  fi

  doctor_check_env_file
  doctor_check_blocks

  doctor_check_shell zsh -c
  doctor_check_shell zsh -lc
  doctor_check_shell bash -lc
  if mise_find >/dev/null; then
    commands=$(mise_active_commands) || commands=""
    doctor_check_shadowed zsh -lc "$commands"
    doctor_check_shadowed bash -lc "$commands"
  fi
  doctor_check_gui

  case "${SHELL:-}" in
    */fish) doctor_warn "fish is not supported yet" ;;
  esac

  if [ "$DOCTOR_FAILED" -ne 0 ]; then
    printf 'povy doctor found problems.\n'
    return 1
  fi
  printf 'povy doctor: all good.\n'
}
