# shellcheck shell=bash
# Machine configuration: config.toml and the .env secrets file. Neither is ever
# versioned. .env is parsed, never sourced, so its content cannot run as code.

CFG_NAME=""
CFG_EMAIL=""
CFG_PROFILE=""
CFG_PROFILE_BRANCH=""
CFG_TOOLS=""
CFG_IDENTITIES=""
CFG_PACKAGES=""
CFG_BANNER=true
CFG_PROMPT=""
BIVY_STARSHIP_TOOL="starship@1.27.0"

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

# Prints "name<TAB>versions<TAB>level" for every tool, the last declaration of a
# name winning: bivy itself, then the profile, then the machine. yq is declared
# because mise creates a shim for every installed tool, and a shim with no
# configured version fails when called.
tools_merged() {
  {
    printf '%s\t%s\tbivy\n' "${BIVY_YQ_TOOL%@*}" "${BIVY_YQ_TOOL#*@}"
    if [ "$(prompt_choice)" = starship ]; then
      printf '%s\t%s\tbivy\n' "${BIVY_STARSHIP_TOOL%@*}" "${BIVY_STARSHIP_TOOL#*@}"
    fi
    printf '%s\n' "$PROFILE_TOOLS" | awk -F'\t' 'NF == 2 { print $0 "\tprofile" }'
    printf '%s\n' "$CFG_TOOLS" | awk -F'\t' 'NF == 2 { print $0 "\tmachine" }'
  } | awk -F'\t' 'NF == 3 { if (!($1 in v)) o[++n] = $1; v[$1] = $2; l[$1] = $3 }
      END { for (i = 1; i <= n; i++) print o[i] "\t" v[o[i]] "\t" l[o[i]] }'
}

# Prints "name<TAB>versions" lines for a [tools] table. A tool takes one version or
# a list of them, separated by spaces in the output. As in mise, every version of a
# list is installed and the first one is the default.
toml_tools() {
  local file=$1 raw name tag length versions version count
  local -a list
  raw=$(toml_tsv "$file" '(.tools // {}) | to_entries | .[] |
    [.key, (.value | tag), ((.value | select(tag == "!!seq") | length) // 1),
      ((.value | select(tag == "!!seq") | map(tostring) | join(" ")) // (.value | tostring))]') ||
    die "$file is not valid TOML"
  # The version comes last because it may be empty, and read merges empty fields.
  while IFS=$'\t' read -r name tag length versions; do
    [ -n "$name" ] || continue
    [[ "$name" =~ $BIVY_TOOL_NAME_RE ]] || die "$file: invalid tool name: $name"
    if [ "$tag" != '!!seq' ]; then
      [[ "$versions" =~ $BIVY_TOOL_VERSION_RE ]] || die "$file: invalid version for $name"
    else
      # read -a splits without expanding wildcards, which are checked below.
      IFS=' ' read -r -a list <<<"$versions"
      for version in ${list[@]+"${list[@]}"}; do
        [[ "$version" =~ $BIVY_TOOL_VERSION_RE ]] || die "$file: invalid version for $name"
      done
      # An element holding a space would split into several valid-looking words.
      count=${#list[@]}
      [ "$count" -gt 0 ] && [ "$count" -eq "$length" ] || die "$file: invalid version list for $name"
    fi
    printf '%s\t%s\n' "$name" "$versions"
  done <<<"$raw"
}

# A directory for includeIf "gitdir:", absolute or under ~/. A trailing slash makes
# it match every repository below, which is what a directory of projects needs.
identity_dir() {
  local dir=$1
  # A literal ~/, which Git expands itself.
  # shellcheck disable=SC2088
  case "$dir" in
    '~/'?* | /?*) ;;
    *) return 1 ;;
  esac
  ! has_control_chars "$dir" || return 1
  case "$dir" in
    */) printf '%s' "$dir" ;;
    *) printf '%s/' "$dir" ;;
  esac
}

# Prints "dir<TAB>name<TAB>email" for each [[identities]] entry. The name defaults
# to the top-level one, which must be read first. Every field is checked against
# control characters, so tabs and newlines cannot shift the columns.
toml_identities() {
  local file=$1 tag count i entry dir name email
  tag=$(toml_query "$file" '(.identities // []) | tag') || die "$file is not valid TOML"
  [ "$tag" = '!!seq' ] || die "$file: identities must be written as [[identities]] tables"
  count=$(toml_query "$file" '(.identities // []) | length') || die "$file is not valid TOML"
  i=0
  while [ "$i" -lt "$count" ]; do
    entry="identities entry $((i + 1))"
    tag=$(toml_query "$file" ".identities[$i] | tag") || die "$file is not valid TOML"
    [ "$tag" = '!!map' ] || die "$file: $entry must be a table"
    dir=$(toml_string "$file" "identities[$i].dir") || exit 1
    name=$(toml_string "$file" "identities[$i].name") || exit 1
    email=$(toml_string "$file" "identities[$i].email") || exit 1
    dir=$(identity_dir "$dir") || die "$file: $entry: dir must start with ~/ or /"
    [ -n "$name" ] || name=$CFG_NAME
    valid_name "$name" || die "$file: $entry: invalid name"
    valid_email "$email" || die "$file: $entry: email is not a valid address"
    printf '%s\t%s\t%s\n' "$dir" "$name" "$email"
    i=$((i + 1))
  done
}

# Prints true or false for a top-level boolean, or the default when it is absent.
toml_bool() {
  local file=$1 key=$2 default=$3 tag
  tag=$(toml_query "$file" ".$key | tag") || die "$file is not valid TOML"
  case "$tag" in
    '!!null') printf '%s' "$default" ;;
    '!!bool') toml_query "$file" ".$key" ;;
    *) die "$file: $key must be true or false" ;;
  esac
}

# Prints the prompt key of a file: starship, none, or nothing when it is absent.
toml_prompt() {
  local file=$1 value
  value=$(toml_string "$file" prompt) || exit 1
  case "$value" in
    '' | starship | none) printf '%s' "$value" ;;
    *) die "$file: prompt must be starship or none" ;;
  esac
}

# The prompt to set: the machine's choice, else the profile's, else none.
prompt_choice() {
  local choice=${CFG_PROMPT:-${PROFILE_PROMPT:-}}
  printf '%s' "${choice:-none}"
}

config_read() {
  local file=$1 problem
  CFG_NAME=$(toml_string "$file" name) || exit 1
  CFG_EMAIL=$(toml_string "$file" email) || exit 1
  CFG_PROFILE=$(toml_string "$file" profile) || exit 1
  CFG_PROFILE_BRANCH=$(toml_string "$file" profile_branch) || exit 1
  CFG_TOOLS=$(toml_tools "$file") || exit 1
  valid_name "$CFG_NAME" || die "$file: name is required"
  valid_email "$CFG_EMAIL" || die "$file: email is not a valid address"
  if [ -n "$CFG_PROFILE_BRANCH" ]; then
    [ -n "$CFG_PROFILE" ] || die "$file: profile_branch needs a profile"
    [[ "$CFG_PROFILE_BRANCH" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] && [[ "$CFG_PROFILE_BRANCH" != *..* ]] ||
      die "$file: invalid profile_branch: $CFG_PROFILE_BRANCH"
  fi
  problem=$(profile_url_problem "$CFG_PROFILE")
  [ -z "$problem" ] || die "$file: $problem"
  CFG_IDENTITIES=$(toml_identities "$file") || exit 1
  CFG_BANNER=$(toml_bool "$file" banner true) || exit 1
  CFG_PROMPT=$(toml_prompt "$file") || exit 1
  CFG_PACKAGES=$(toml_packages "$file") || exit 1
}

config_load() {
  [ -f "$BIVY_CONFIG_FILE" ] || die "$BIVY_CONFIG_FILE not found; run: bivy init"
  config_read "$BIVY_CONFIG_FILE"
}

BIVY_CONFIG_HEADER='# Machine configuration for bivy. Never versioned.'

# Rewrites the three answers of bivy init. The rest of an existing file, such as
# [tools] or [[identities]], is kept as it is.
config_write() {
  local name=$1 email=$2 profile=$3 tmp
  tmp=$(mktemp "$BIVY_STATE_DIR/config.XXXXXX") || die "cannot write in $BIVY_STATE_DIR"
  {
    printf '%s\n' "$BIVY_CONFIG_HEADER"
    printf 'name = "%s"\n' "$(toml_escape "$name")"
    printf 'email = "%s"\n' "$(toml_escape "$email")"
    printf 'profile = "%s"\n' "$(toml_escape "$profile")"
    if [ -f "$BIVY_CONFIG_FILE" ]; then
      awk -v header="$BIVY_CONFIG_HEADER" '
        /^[[:space:]]*\[/ { tables = 1 }
        !tables && /^[[:space:]]*(name|email|profile)[[:space:]]*=/ { next }
        !tables && $0 == header { next }
        { print }
      ' "$BIVY_CONFIG_FILE"
    fi
  } >"$tmp"
  if ! (config_read "$tmp"); then
    rm -f "$tmp"
    die "could not update $BIVY_CONFIG_FILE; fix it by hand or remove it"
  fi
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
