# shellcheck shell=bash
# bivy doctor: reports the real state and changes nothing. Exits 0 when all checks
# pass, 1 when at least one fails. Warnings do not change the exit code.

DOCTOR_FAILED=0

doctor_ok() { printf '[ok]   %s\n' "$*"; }
doctor_warn() { printf '[warn] %s\n' "$*"; }
doctor_fail() {
  printf '[FAIL] %s\n' "$*"
  DOCTOR_FAILED=1
}

# Runs a command in a shell started from an almost empty environment, the way an
# IDE or an agent would. Only the startup files can put the shims on its PATH.
# It runs from HOME because mise shims refuse to run under a directory holding an
# untrusted mise.toml, which says nothing about this machine's setup.
doctor_probe() {
  local shell_cmd=$1 flags=$2 script=$3
  cd "$HOME" && env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin \
    ${ZDOTDIR:+ZDOTDIR="$ZDOTDIR"} \
    ${MISE_DATA_DIR:+MISE_DATA_DIR="$MISE_DATA_DIR"} \
    ${MISE_CONFIG_DIR:+MISE_CONFIG_DIR="$MISE_CONFIG_DIR"} \
    ${XDG_CONFIG_HOME:+XDG_CONFIG_HOME="$XDG_CONFIG_HOME"} \
    ${XDG_DATA_HOME:+XDG_DATA_HOME="$XDG_DATA_HOME"} \
    "$shell_cmd" "$flags" "$script" </dev/null 2>/dev/null | tail -n 1
}

doctor_check_shell() {
  local shell_cmd=$1 flags=$2 label="$1 $2" resolved
  command -v "$shell_cmd" >/dev/null 2>&1 || return 0
  resolved=$(doctor_probe "$shell_cmd" "$flags" 'command -v yq') || resolved=""
  if [ "$resolved" != "$BIVY_SHIMS_DIR/yq" ]; then
    doctor_fail "shims not visible from a non-interactive '$label' (yq: ${resolved:-not found})"
  elif ! (doctor_probe "$shell_cmd" "$flags" 'yq --version') | grep -q version; then
    doctor_fail "the yq shim does not run from a non-interactive '$label'"
  else
    doctor_ok "shims visible from a non-interactive '$label'"
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

doctor_check_packages() {
  local wanted missing names here manager name count managers
  wanted=$(packages_wanted)
  [ -n "$wanted" ] || return 0
  missing=$(packages_missing "$wanted")
  names=$(printf '%s\n' "$missing" | awk -F'\t' '$1 == "none" { print $2 }' | tr '\n' ' ')
  [ -z "$names" ] || doctor_warn "no package manager here for: $names"
  names=$(printf '%s\n' "$missing" | awk -F'\t' 'NF == 2 && $1 != "none" { print $1 ":" $2 }' | tr '\n' ' ')
  names=${names% }
  if [ -n "$names" ]; then
    doctor_fail "packages not installed: $names; run: bivy apply"
    return 0
  fi
  # Lists for managers absent here, such as apt on macOS, are not counted.
  here=$(printf '%s\n' "$wanted" | while IFS=$'\t' read -r manager name; do
    [ -z "$(packages_command "$manager")" ] || printf '%s\t%s\n' "$manager" "$name"
  done)
  [ -n "$here" ] || return 0
  count=$(printf '%s\n' "$here" | wc -l | tr -d ' ')
  managers=$(printf '%s\n' "$here" | awk -F'\t' '!seen[$1]++ { printf "%s%s", (n++ ? ", " : ""), $1 }')
  doctor_ok "packages: $count installed with $managers"
}

doctor_check_prompt() {
  [ "$(prompt_choice)" = starship ] || return 0
  if [ -n "$(prompt_starship_path)" ]; then
    doctor_ok "prompt: starship"
  else
    doctor_fail "starship is not installed; run: bivy apply"
  fi
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
  else
    doctor_ok "mise $version"
  fi
}

doctor_check_env_file() {
  local mode
  if [ ! -f "$BIVY_ENV_FILE" ]; then
    doctor_fail "$BIVY_ENV_FILE is missing"
    return 0
  fi
  mode=$(os_file_mode "$BIVY_ENV_FILE")
  if [ "$mode" = 600 ]; then
    doctor_ok "$BIVY_ENV_FILE has mode 600"
  else
    doctor_fail "$BIVY_ENV_FILE has mode $mode, expected 600"
  fi
}

doctor_check_blocks() {
  local files file parts position name label
  files=$(shell_startup_files)
  while IFS=$'\t' read -r file parts position name; do
    [ -n "$file" ] || continue
    label="bivy${name:+ $name} block"
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
    doctor_fail "$file is missing; run: bivy apply"
  elif ! cmp -s "$expected" "$file"; then
    doctor_fail "$file is outdated; run: bivy apply"
  else
    doctor_ok "$label"
  fi
}

doctor_check_gui() {
  local tmp file state
  file=$(os_gui_file)
  if ! tmp=$(mktemp "${TMPDIR:-/tmp}/bivy-gui.XXXXXX"); then
    doctor_fail "cannot create a temporary file to check $file"
    return 0
  fi
  if os_gui_render "$tmp"; then
    doctor_check_generated "$file" "$tmp" "graphical apps get the shims at login: $file"
    os_gui_session_state && state=0 || state=$?
    case "$state" in
      0) doctor_ok "shims on the PATH of graphical apps" ;;
      1) doctor_warn "graphical apps started now do not see the shims; run bivy apply, or log out and back in" ;;
    esac
  else
    doctor_warn "graphical apps: $BIVY_SHIMS_DIR cannot be written safely in $file"
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
  if [ -f "$global" ] && grep -qxF "$BIVY_BLOCK_START" "$global"; then
    doctor_ok "bivy block in $global"
  else
    doctor_fail "no bivy block in $global"
    return 0
  fi

  if ! stage=$(mktemp -d "${TMPDIR:-/tmp}/bivy-git.XXXXXX"); then
    doctor_fail "cannot create a temporary directory to check $BIVY_GIT_DIR"
    return 0
  fi
  if ! git_render "$stage"; then
    rm -rf "$stage"
    doctor_fail "could not generate the Git configuration"
    return 0
  fi
  for file in "$stage"/*; do
    name=${file##*/}
    if [ ! -f "$BIVY_GIT_DIR/$name" ] || ! cmp -s "$file" "$BIVY_GIT_DIR/$name"; then
      stale=1
    fi
    case "$name" in identity-*) count=$((count + 1)) ;; esac
  done
  for file in "$BIVY_GIT_DIR"/identity-*; do
    [ ! -e "$file" ] || [ -e "$stage/${file##*/}" ] || stale=1
  done
  rm -rf "$stage"
  if [ "$stale" -ne 0 ]; then
    doctor_fail "$BIVY_GIT_DIR does not match config.toml; run: bivy apply"
    return 0
  fi
  doctor_ok "Git identity $CFG_EMAIL, and $count by directory"

  overriding=$(git_overriding_files)
  if [ -n "$overriding" ]; then
    doctor_warn "set after the bivy include, user.name or user.email overrides it in: $(printf '%s' "$overriding" | tr '\n' ' ')"
  fi
}

doctor_check_profile() {
  local missing source target path mode
  if ! (profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH") 2>/dev/null; then
    doctor_fail "the profile is missing or invalid; run: bivy apply"
    return 0
  fi
  profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  [ -z "$CFG_PROFILE" ] || doctor_ok "profile $CFG_PROFILE${CFG_PROFILE_BRANCH:+, branch $CFG_PROFILE_BRANCH}${CFG_PROFILE_PATH:+, path $CFG_PROFILE_PATH}"
  if [ -n "$PROFILE_BIN" ]; then
    # shellcheck disable=SC2016 # Expanded by the probed shell.
    case ":$(doctor_probe bash -lc 'printf "%s\n" "$PATH"'):" in
      *":$BIVY_PROFILE_ROOT/$PROFILE_BIN:"*) doctor_ok "profile commands on PATH: $PROFILE_BIN" ;;
      *) doctor_fail "the profile commands in $PROFILE_BIN are not on PATH; run: bivy apply" ;;
    esac
  fi

  missing=$(env_missing "$PROFILE_SECRETS")
  if [ -n "$missing" ]; then
    doctor_fail "empty secrets in $BIVY_ENV_FILE: $(printf '%s' "$missing" | tr '\n' ' ')"
  elif [ -n "$PROFILE_SECRETS" ]; then
    doctor_ok "required secrets are set"
  fi

  while IFS=$'\t' read -r source target; do
    [ -n "$source" ] || continue
    path="$HOME/$target"
    if [ ! -f "$path" ]; then
      doctor_fail "$path is missing"
      continue
    fi
    mode=$(os_file_mode "$path")
    if [ "$mode" = 600 ]; then
      doctor_ok "$path has mode 600"
    else
      doctor_fail "$path has mode $mode, expected 600"
    fi
  done <<<"$PROFILE_FILES"
}

cmd_doctor() {
  local commands
  [ $# -eq 0 ] || die "doctor takes no argument"

  bivy_init_paths
  bivy_load_os
  doctor_check_mise
  os_doctor

  if yq_resolve; then
    doctor_ok "$BIVY_YQ_TOOL available"
  else
    doctor_fail "$BIVY_YQ_TOOL is not installed; run: bivy init"
  fi

  if [ ! -f "$BIVY_CONFIG_FILE" ]; then
    doctor_fail "$BIVY_CONFIG_FILE is missing; run: bivy init"
  elif [ -z "$BIVY_YQ" ]; then
    doctor_fail "$BIVY_CONFIG_FILE cannot be read without yq"
  elif ! (config_load) 2>/dev/null; then
    doctor_fail "$BIVY_CONFIG_FILE is invalid"
  else
    doctor_ok "$BIVY_CONFIG_FILE is valid"
    config_load
    doctor_check_profile
    doctor_check_git
    doctor_check_prompt
    doctor_check_packages
  fi

  doctor_check_env_file
  doctor_check_blocks

  if [ -f "$BIVY_MISE_CONF" ]; then
    doctor_ok "$BIVY_MISE_CONF present"
  else
    doctor_fail "$BIVY_MISE_CONF is missing; run: bivy apply"
  fi

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
    printf 'bivy doctor found problems.\n'
    return 1
  fi
  printf 'bivy doctor: all good.\n'
}
