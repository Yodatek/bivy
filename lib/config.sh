# shellcheck shell=bash
# Machine configuration: config.toml and the .env secrets file. Neither is ever
# versioned. .env is parsed, never sourced, so its content cannot run as code.

CFG_NAME=""
CFG_EMAIL=""
CFG_PROFILE=""
CFG_TOOLS=""

BIVY_TOOL_NAME_RE='^[A-Za-z0-9@][A-Za-z0-9@._:/+-]*$'
BIVY_TOOL_VERSION_RE='^[A-Za-z0-9][A-Za-z0-9._:+-]*$'

valid_name() {
  [ -n "$1" ] && ! has_control_chars "$1"
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] && ! has_control_chars "$1"
}

# An empty URL means no profile. Credentials do not belong in config.toml.
profile_url_problem() {
  local url=$1
  case "$url" in
    '') return 0 ;;
    -* | ext::* | fd::*)
      echo "unsupported profile URL: $url"
      return 0
      ;;
    *[[:space:]]* | *[[:cntrl:]]*)
      echo "profile URL contains whitespace or control characters"
      return 0
      ;;
  esac
  if [[ "$url" =~ ://[^/@]+:[^/@]+@ ]]; then
    echo "profile URL must not embed a password; use a Git credential helper or SSH"
  fi
  return 0
}

# Prints "name<TAB>version" lines for a [tools] table.
toml_tools() {
  local file=$1 raw name version
  raw=$(toml_tsv "$file" '(.tools // {}) | to_entries | .[] | [.key, (.value | tostring)]') ||
    die "$file is not valid TOML"
  while IFS=$'\t' read -r name version; do
    [ -n "$name" ] || continue
    [[ "$name" =~ $BIVY_TOOL_NAME_RE ]] || die "$file: invalid tool name: $name"
    [[ "$version" =~ $BIVY_TOOL_VERSION_RE ]] || die "$file: invalid version for $name"
    printf '%s\t%s\n' "$name" "$version"
  done <<<"$raw"
}

config_read() {
  local file=$1 problem
  CFG_NAME=$(toml_string "$file" name) || exit 1
  CFG_EMAIL=$(toml_string "$file" email) || exit 1
  CFG_PROFILE=$(toml_string "$file" profile) || exit 1
  CFG_TOOLS=$(toml_tools "$file") || exit 1
  valid_name "$CFG_NAME" || die "$file: name is required"
  valid_email "$CFG_EMAIL" || die "$file: email is not a valid address"
  problem=$(profile_url_problem "$CFG_PROFILE")
  [ -z "$problem" ] || die "$file: $problem"
}

config_load() {
  [ -f "$BIVY_CONFIG_FILE" ] || die "$BIVY_CONFIG_FILE not found; run: bivy init"
  config_read "$BIVY_CONFIG_FILE"
}

config_write() {
  local name=$1 email=$2 profile=$3 tmp
  tmp=$(mktemp "$BIVY_STATE_DIR/config.XXXXXX") || die "cannot write in $BIVY_STATE_DIR"
  {
    echo '# Machine configuration for bivy. Never versioned.'
    printf 'name = "%s"\n' "$(toml_escape "$name")"
    printf 'email = "%s"\n' "$(toml_escape "$email")"
    printf 'profile = "%s"\n' "$(toml_escape "$profile")"
  } >"$tmp"
  install_file "$tmp" "$BIVY_CONFIG_FILE" 600
  rm -f "$tmp"
}

env_ensure() {
  if [ ! -e "$BIVY_ENV_FILE" ]; then
    (umask 077 && echo '# Secrets for bivy. Never versioned.' >"$BIVY_ENV_FILE") ||
      die "cannot create $BIVY_ENV_FILE"
    info "wrote $BIVY_ENV_FILE"
  fi
  chmod 600 "$BIVY_ENV_FILE"
}

# Prints the value of a key, or returns 1 when the key has no line. The last line
# wins, as it would in a shell. Surrounding quotes are removed, CRLF is tolerated.
env_value() {
  local key=$1 line value found=1
  [ -f "$BIVY_ENV_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#export }
    case "$line" in
      "$key="*)
        value=${line#*=}
        found=0
        ;;
    esac
  done <"$BIVY_ENV_FILE"
  [ "$found" -eq 0 ] || return 1
  case "$value" in
    \"*\") value=${value#\"} && value=${value%\"} ;;
    \'*\') value=${value#\'} && value=${value%\'} ;;
  esac
  printf '%s' "$value"
}

# Adds an empty line for each listed key that has none; existing lines stay.
env_seed() {
  local keys=$1 key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    env_value "$key" >/dev/null && continue
    if [ -s "$BIVY_ENV_FILE" ] && [ -n "$(tail -c 1 "$BIVY_ENV_FILE")" ]; then
      echo >>"$BIVY_ENV_FILE"
    fi
    printf '%s=\n' "$key" >>"$BIVY_ENV_FILE"
  done <<<"$keys"
}

# Prints the listed keys whose value is empty or missing.
env_missing() {
  local keys=$1 key value
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value=$(env_value "$key") || value=""
    [ -n "$value" ] || printf '%s\n' "$key"
  done <<<"$keys"
}
