# shellcheck shell=bash
# povy apply: points mise at the profile and lets mise bootstrap apply it, then
# makes the tools visible where mise does not reach: shells started without mise
# on their PATH, and graphical apps. Idempotent, and nothing in the home directory
# changes until the secrets the profile needs are filled in.

# What povy banner shows without reading the configuration again. Rewritten on
# every apply: its date is the date of the last one.
apply_write_status() {
  local tmp
  tmp=$(mktemp "$POVY_STATE_DIR/applied.XXXXXX") || die "cannot write in $POVY_STATE_DIR"
  {
    echo '# Written by povy apply for povy banner.'
    printf 'profile\t%s\n' "$CFG_PROFILE"
  } >"$tmp"
  mv -f "$tmp" "$POVY_APPLIED" || die "cannot write $POVY_APPLIED"
}

cmd_apply() {
  local names missing
  [ $# -eq 0 ] || die "unknown option for apply: $1"
  povy_init_paths
  povy_load_os
  os_preflight
  povy_ensure_dirs
  mise_require_recent
  yq_ensure
  config_load
  env_ensure
  profile_sync "$CFG_PROFILE" "$CFG_PROFILE_REF"
  profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
  team_trust
  names=$(team_secret_names)
  env_seed "$names"
  missing=$(team_secrets_missing "$names")
  if [ -n "$missing" ]; then
    info "$missing"
    die "the secrets above are empty; fill them in $POVY_ENV_FILE"
  fi

  team_conf_write
  if [ -n "$PROFILE_PROJECT" ]; then
    team_backup_files "$names"
    team_bootstrap "$names"
  else
    team_install_tools
  fi
  mise_run reshim >&2 || die "mise could not refresh its shims"

  shell_write_env
  shell_write_interactive
  shell_apply_blocks
  gui_apply
  git_apply

  case "${SHELL:-}" in
    */fish) warn "fish is not supported yet; add $POVY_SHIMS_DIR to its PATH yourself" ;;
  esac
  apply_write_status
  info "Applied: $POVY_WRITTEN written, $POVY_UNCHANGED unchanged, $POVY_BACKED_UP backed up."
  if [ "$POVY_BACKED_UP" -gt 0 ]; then
    info "Backups are in $POVY_BACKUP_DIR"
  fi
}
