# shellcheck shell=bash
# povy apply: points mise at the profiles, the default one and those of the
# contexts, and lets mise bootstrap apply them, then makes the tools visible where
# mise does not reach: shells started without mise on their PATH, and graphical
# apps. Idempotent, and nothing in the home directory changes until the secrets the
# profiles need are filled in.

# What povy banner shows without reading the configuration again: the default
# profile and the directory of each context. Rewritten on every apply: its date is
# the date of the last one.
apply_write_status() {
  local tmp
  tmp=$(mktemp "$POVY_STATE_DIR/applied.XXXXXX") || die "cannot write in $POVY_STATE_DIR"
  {
    echo '# Written by povy apply for povy banner.'
    printf 'profile\t%s\n' "$CFG_DEFAULT_PROFILE"
    printf '%s\n' "$CFG_CONTEXTS" | awk -F'\t' 'NF { print "context\t" $1 "\t" $2 }'
  } >"$tmp"
  mv -f "$tmp" "$POVY_APPLIED" || die "cannot write $POVY_APPLIED"
}

cmd_apply() {
  local id names missing="" targets="" bins="" conflicts collisions
  [ $# -eq 0 ] || die "unknown option for apply: $1"
  povy_init_paths
  povy_load_os
  os_preflight
  povy_ensure_dirs
  mise_require_recent
  yq_ensure
  config_load
  env_ensure

  # Every profile is updated and read, and its secrets checked, before anything in
  # the home directory changes: the default profile first, then the contexts.
  for id in "" $(context_ids); do
    context_select "$id"
    [ -n "$CFG_PROFILE" ] || continue
    [ -z "$id" ] || info "context $id, in $(tilde_path "$CONTEXT_DIR")"
    profile_sync "$CFG_PROFILE" "$CFG_PROFILE_REF"
    profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
    team_trust
    names=$(team_secret_names)
    env_seed "$names"
    [ ! -f "$POVY_ENV_FILE" ] || chmod 600 "$POVY_ENV_FILE" || die "cannot change the mode of $POVY_ENV_FILE"
    names=$(team_secrets_missing "$names")
    [ -z "$names" ] || missing="$missing$names"$'\n'"  in $(tilde_path "$POVY_ENV_FILE")"$'\n'
    targets="$targets$(profile_file_targets | awk -v owner="$id" '{ print owner "\t" $0 }')"$'\n'
    [ -z "$PROFILE_BIN" ] || bins="$bins$id"$'\t'"$PROFILE_BIN"$'\n'
  done
  if [ -n "$missing" ]; then
    info "${missing%$'\n'}"
    die "the secrets above are empty; fill them in, then run povy apply again"
  fi
  conflicts=$(context_conflicts "$targets")
  if [ -n "$conflicts" ]; then
    info "$(context_conflicts_text "$conflicts")"
    die "two profiles write the same files; keep one, or have the other write elsewhere"
  fi

  for id in "" $(context_ids); do
    context_select "$id"
    [ -z "$CFG_PROFILE" ] || profile_load "$CFG_PROFILE" "$CFG_PROFILE_PATH"
    if [ -z "$id" ]; then
      team_conf_write
    else
      context_conf_apply
      if [ -z "$CFG_PROFILE" ]; then
        # A context that only sets an identity has no clone.
        rm -rf "${POVY_STATE_DIR:?}/contexts/$id"
        continue
      fi
    fi
    if [ -n "$PROFILE_PROJECT" ]; then
      names=$(team_secret_names)
      team_backup_files "$names"
      team_bootstrap "$names"
    fi
    # mise bootstrap installs the tools that apply in every directory; a context's
    # team.toml applies only below its own.
    if { [ -n "$id" ] && [ -n "$PROFILE_TEAM" ]; } || { [ -z "$id" ] && [ -z "$PROFILE_PROJECT" ]; }; then
      team_install_tools
    fi
  done
  context_select ""
  context_cleanup
  mise_run reshim >&2 || die "mise could not refresh its shims"

  POVY_BINS=$(printf '%s' "$bins" | cut -f2)
  shell_write_env
  shell_write_interactive
  shell_apply_blocks
  gui_apply
  git_apply
  collisions=$(context_bin_collisions "$bins")
  [ -z "$collisions" ] || warn "two profiles have commands of the same name:"$'\n'"$(context_bin_collisions_text "$collisions")"

  case "${SHELL:-}" in
    */fish) warn "fish is not supported yet; add $POVY_SHIMS_DIR to its PATH yourself" ;;
  esac
  apply_write_status
  info "Applied: $POVY_WRITTEN written, $POVY_UNCHANGED unchanged, $POVY_BACKED_UP backed up."
  if [ "$POVY_BACKED_UP" -gt 0 ]; then
    info "Backups are in $POVY_BACKUP_DIR"
  fi
}
