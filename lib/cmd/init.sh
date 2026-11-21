# shellcheck shell=bash
# povy init: writes config.toml and .env, then opens .env if the profile needs it.

init_from_config() {
  local file=$1
  [ -r "$file" ] && [ -f "$file" ] || die "cannot read $file"
  case "$file" in
    /*) ;;
    *) file="$PWD/$file" ;;
  esac
  config_read "$file"
  if [ "$file" != "$POVY_CONFIG_FILE" ]; then
    install_file "$file" "$POVY_CONFIG_FILE" 600
  fi
  chmod 600 "$POVY_CONFIG_FILE"
}

init_prompt() {
  local name="" email="" profile="" problem
  tty_available || die "no terminal available; use: povy init --config <file>"
  if [ -f "$POVY_CONFIG_FILE" ]; then
    config_read "$POVY_CONFIG_FILE"
    name=$CFG_NAME
    email=$CFG_EMAIL
    profile=$CFG_PROFILE
  else
    name=$(git config --global user.name 2>/dev/null) || name=""
    email=$(git config --global user.email 2>/dev/null) || email=""
  fi

  exec 3<"$(tty_path)"
  while :; do
    tty_ask "Name" "$name"
    valid_name "$ANSWER" && break
    info "A name is required."
  done
  name=$ANSWER
  while :; do
    tty_ask "E-mail" "$email"
    valid_email "$ANSWER" && break
    info "That does not look like an e-mail address."
  done
  email=$ANSWER
  while :; do
    tty_ask "Profile Git URL (optional, 'none' for no profile)" "$profile"
    [ "$ANSWER" != none ] || ANSWER=""
    problem=$(profile_url_problem "$ANSWER")
    [ -n "$problem" ] || break
    info "$problem"
  done
  profile=$ANSWER
  exec 3<&-

  config_write "$name" "$email" "$profile"
}

init_edit_env() {
  local editor=${EDITOR:-${VISUAL:-vi}} tty
  tty=$(tty_path)
  # shellcheck disable=SC2016,SC2094
  sh -c "$editor \"\$1\"" povy-editor "$POVY_ENV_FILE" <"$tty" >>"$tty" ||
    warn "the editor exited with an error"
  chmod 600 "$POVY_ENV_FILE"
}

cmd_init() {
  local config_file="" interactive=1 missing
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        [ $# -ge 2 ] || die "--config needs a file"
        config_file=$2
        interactive=0
        shift 2
        ;;
      *) die "unknown option for init: $1" ;;
    esac
  done

  povy_init_paths
  povy_load_os
  os_preflight
  povy_ensure_dirs
  yq_ensure

  if [ "$interactive" -eq 1 ]; then
    init_prompt
  else
    init_from_config "$config_file"
  fi

  env_ensure
  config_load
  profile_sync "$CFG_PROFILE" "$CFG_PROFILE_BRANCH"
  profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  env_seed "$PROFILE_SECRETS"

  missing=$(env_missing "$PROFILE_SECRETS")
  if [ -n "$missing" ] && [ "$interactive" -eq 1 ]; then
    info "The profile needs secrets; opening $POVY_ENV_FILE"
    init_edit_env
    missing=$(env_missing "$PROFILE_SECRETS")
  fi
  if [ -n "$missing" ]; then
    warn "fill these secrets in $POVY_ENV_FILE before povy apply:"
    info "$missing"
  fi
  info "Next: povy apply"
}
