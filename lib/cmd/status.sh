# shellcheck shell=bash
# povy status: the contexts and the [[identities]] entries that apply in a
# directory, the current one by default, the deepest first, as mise and Git apply
# them, then the default profile and identity, which every directory gets unless a
# context sets its own.

# The repository name of a profile URL.
status_profile_name() {
  local name=${1%/}
  name=${name%.git}
  printf '%s' "${name##*[/:]}"
}

status_line() {
  local label=$1 where=$2 email=$3 profile=$4 ref=$5 what=""
  [ -z "$profile" ] || what="profile $(status_profile_name "$profile")${ref:+ at $ref}"
  [ -z "$email" ] || what="$what${what:+, }Git identity $email"
  printf '  %-12s %s: %s\n' "$label" "$where" "${what:-nothing}"
}

cmd_status() {
  local dir=${1:-$PWD} kind key email
  [ $# -le 1 ] || die "status takes at most one directory"
  povy_init_paths
  yq_resolve || die "$POVY_YQ_TOOL is not installed; run: povy init"
  config_load
  dir=$(cd "$dir" 2>/dev/null && pwd) || die "no such directory: $dir"
  printf '%s, the first that sets something wins:\n' "$(tilde_path "$dir")"
  while IFS=$'\t' read -r kind key email; do
    case "$kind" in
      context)
        status_line "$key" "$(context_field "$key" 2)" "$(context_field "$key" 4)" \
          "$(context_field "$key" 5)" "$(context_field "$key" 6)"
        ;;
      identity) status_line '(identity)' "$key" "$email" "" "" ;;
    esac
  done <<<"$(context_matching "$dir")"
  status_line '(default)' 'every directory' "$CFG_EMAIL" "$CFG_DEFAULT_PROFILE" "$CFG_DEFAULT_PROFILE_REF"
}
