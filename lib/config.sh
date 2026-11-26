# shellcheck shell=bash
# Machine configuration: config.toml and the .env secrets file. Neither is ever
# versioned. .env is parsed, never sourced, so its content cannot run as code.
# Tools, packages and the prompt are mise configuration now, not povy's.

CFG_NAME=""
CFG_EMAIL=""
CFG_PROFILE=""
CFG_PROFILE_REF=""
CFG_PROFILE_PATH=""
CFG_IDENTITIES=""
CFG_CONTEXTS=""
# The variables of the contexts, "id<TAB>name<TAB>value" lines, in the order of
# config.toml.
CFG_CONTEXT_ENV=""
CFG_BANNER=true
# The top-level profile, which applies in every directory. CFG_PROFILE and the
# keys after it hold the profile of the current context, which context_select sets.
CFG_DEFAULT_PROFILE=""
CFG_DEFAULT_PROFILE_REF=""
CFG_DEFAULT_PROFILE_PATH=""

POVY_REF_RE='^[A-Za-z0-9_][A-Za-z0-9._/-]*$'
POVY_CONTEXT_ID_RE='^[a-z0-9][a-z0-9-]*$'
# An environment variable: a context's, or the one a profile's secret is read from.
POVY_ENV_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'
# The shared .env, which a context reads after its own <id>.env.
POVY_ENV_FALLBACK=""

valid_name() {
  [ -n "$1" ] && ! has_control_chars "$1"
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] && ! has_control_chars "$1"
}

# A branch, a tag or a commit that git checkout takes, and never an option.
valid_ref() {
  [[ "$1" =~ $POVY_REF_RE ]] && [[ "$1" != *..* ]]
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

# Settings that povy 0.1 read and that belong to mise now. A config that still has
# them stops with the way out, rather than having them ignored.
config_reject_legacy() {
  local file=$1 legacy
  legacy=$(toml_query "$file" '[keys[] | select(. == "tools" or . == "packages" or . == "prompt")] | join(" ")') ||
    die "$file is not valid TOML"
  [ -z "$legacy" ] ||
    die "$file: $legacy: since povy 0.2, tools, packages and the prompt are mise configuration; move them to ~/.config/mise/config.toml or to the profile's team.toml and mise.toml"
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

# Prints "id<TAB>dir<TAB>name<TAB>email<TAB>profile<TAB>ref<TAB>path" for each
# [contexts.<id>] table, in the order of the file. A context sets a Git identity, a
# profile, variables, or several, below its directory; toml_context_env reads the
# variables. Every field is checked against control characters, so tabs and
# newlines cannot shift the columns.
toml_contexts() {
  local file=$1 tag ids id entry keys key dir name email profile ref path problem seen="" vars
  tag=$(toml_query "$file" '(.contexts // {}) | tag') || die "$file is not valid TOML"
  # yq gives no tag to a table that only dotted headers such as [contexts.a] declare.
  case "$tag" in
    '!!map' | '') ;;
    *) die "$file: contexts must be written as [contexts.<id>] tables" ;;
  esac
  ids=$(toml_query "$file" '(.contexts // {}) | keys | .[]') || die "$file is not valid TOML"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [[ "$id" =~ $POVY_CONTEXT_ID_RE ]] ||
      die "$file: invalid context id: $id; use lowercase letters, digits and dashes"
    entry="contexts.$id"
    tag=$(toml_query "$file" ".contexts[\"$id\"] | tag") || die "$file is not valid TOML"
    case "$tag" in
      '!!map' | '') ;;
      *) die "$file: $entry must be a table" ;;
    esac
    keys=$(toml_query "$file" ".contexts[\"$id\"] | keys | .[]") || die "$file is not valid TOML"
    while IFS= read -r key; do
      case "$key" in
        dir | name | email | profile | profile_ref | profile_path | env) ;;
        *) die "$file: $entry: unknown key: $key" ;;
      esac
    done <<<"$keys"
    dir=$(toml_string "$file" "contexts[\"$id\"].dir") || exit 1
    name=$(toml_string "$file" "contexts[\"$id\"].name") || exit 1
    email=$(toml_string "$file" "contexts[\"$id\"].email") || exit 1
    profile=$(toml_string "$file" "contexts[\"$id\"].profile") || exit 1
    ref=$(toml_string "$file" "contexts[\"$id\"].profile_ref") || exit 1
    path=$(toml_string "$file" "contexts[\"$id\"].profile_path") || exit 1
    [ -n "$dir" ] || die "$file: $entry: dir is required"
    dir=$(identity_dir "$dir") || die "$file: $entry: dir must start with ~/ or /"
    # Its conf.d file would be mise's global one.
    [ "$(context_path "$dir")" != "$HOME" ] || die "$file: $entry: dir must be below your home directory"
    case "$seen" in
      *$'\n'"$dir"$'\n'*) die "$file: $entry: another context has the directory $dir" ;;
    esac
    seen="$seen"$'\n'"$dir"$'\n'
    vars=$(toml_query "$file" "(.contexts[\"$id\"].env // {}) | length") || die "$file is not valid TOML"
    [ -n "$email$profile" ] || [ "$vars" != 0 ] || die "$file: $entry: give it an email, a profile or env"
    if [ -n "$email" ]; then
      [ -n "$name" ] || name=$CFG_NAME
      valid_name "$name" || die "$file: $entry: invalid name"
      valid_email "$email" || die "$file: $entry: email is not a valid address"
    elif [ -n "$name" ]; then
      die "$file: $entry: name needs an email"
    fi
    problem=$(profile_url_problem "$profile")
    [ -z "$problem" ] || die "$file: $entry: $problem"
    if [ -n "$ref" ]; then
      [ -n "$profile" ] || die "$file: $entry: profile_ref needs a profile"
      valid_ref "$ref" || die "$file: $entry: invalid profile_ref: $ref"
    fi
    path=${path%/}
    if [ -n "$path" ]; then
      [ -n "$profile" ] || die "$file: $entry: profile_path needs a profile"
      valid_relative_path "$path" || die "$file: $entry: invalid profile_path: $path"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$dir" "$name" "$email" "$profile" "$ref" "$path"
  done <<<"$ids"
}

# Prints "id<TAB>name<TAB>value" for each variable of a context's env table, which
# povy writes into the context's mise config. A value is a string without control
# characters, which mise reads as written but for a leading ~/: it renders its
# templates, such as {{env.HOME}}. PATH is the business of the profiles' bin and
# of mise's own config.
toml_context_env() {
  local file=$1 id entry tag names name value
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    entry="contexts.$id.env"
    tag=$(toml_query "$file" ".contexts[\"$id\"].env | tag") || die "$file is not valid TOML"
    # As for [contexts.<id>], yq gives no tag to a table that only dotted keys declare.
    case "$tag" in
      '!!null') continue ;;
      '!!map' | '') ;;
      *) die "$file: $entry must be a table of variables, such as env = { NAME = \"value\" }" ;;
    esac
    names=$(toml_query "$file" ".contexts[\"$id\"].env | keys | .[]") || die "$file is not valid TOML"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [[ "$name" =~ $POVY_ENV_NAME_RE ]] && [ "$name" != _ ] || die "$file: $entry: invalid variable name: $name"
      [ "$name" != PATH ] || die "$file: $entry: PATH cannot be set here"
      tag=$(toml_query "$file" ".contexts[\"$id\"].env[\"$name\"] | tag") || die "$file is not valid TOML"
      [ "$tag" = '!!str' ] || die "$file: $entry.$name must be a string"
      value=$(toml_query "$file" ".contexts[\"$id\"].env[\"$name\"]") || die "$file is not valid TOML"
      ! has_control_chars "$value" || die "$file: $entry.$name contains control characters"
      printf '%s\t%s\t%s\n' "$id" "$name" "$value"
    done <<<"$names"
  done <<<"$(printf '%s\n' "$CFG_CONTEXTS" | cut -f1)"
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

config_read() {
  local file=$1 problem branch ref_key=profile_ref
  config_reject_legacy "$file"
  CFG_NAME=$(toml_string "$file" name) || exit 1
  CFG_EMAIL=$(toml_string "$file" email) || exit 1
  CFG_PROFILE=$(toml_string "$file" profile) || exit 1
  CFG_PROFILE_REF=$(toml_string "$file" profile_ref) || exit 1
  branch=$(toml_string "$file" profile_branch) || exit 1
  valid_name "$CFG_NAME" || die "$file: name is required"
  valid_email "$CFG_EMAIL" || die "$file: email is not a valid address"
  # profile_branch is the name povy 0.1 used; profile_ref also takes a tag or a commit.
  if [ -n "$branch" ]; then
    [ -z "$CFG_PROFILE_REF" ] || die "$file: set profile_ref only, profile_branch is its old name"
    CFG_PROFILE_REF=$branch
    ref_key=profile_branch
  fi
  if [ -n "$CFG_PROFILE_REF" ]; then
    [ -n "$CFG_PROFILE" ] || die "$file: $ref_key needs a profile"
    valid_ref "$CFG_PROFILE_REF" || die "$file: invalid $ref_key: $CFG_PROFILE_REF"
  fi
  CFG_PROFILE_PATH=$(toml_string "$file" profile_path) || exit 1
  CFG_PROFILE_PATH=${CFG_PROFILE_PATH%/}
  if [ -n "$CFG_PROFILE_PATH" ]; then
    [ -n "$CFG_PROFILE" ] || die "$file: profile_path needs a profile"
    valid_relative_path "$CFG_PROFILE_PATH" || die "$file: invalid profile_path: $CFG_PROFILE_PATH"
  fi
  problem=$(profile_url_problem "$CFG_PROFILE")
  [ -z "$problem" ] || die "$file: $problem"
  CFG_IDENTITIES=$(toml_identities "$file") || exit 1
  CFG_CONTEXTS=$(toml_contexts "$file") || exit 1
  CFG_CONTEXT_ENV=$(toml_context_env "$file") || exit 1
  CFG_BANNER=$(toml_bool "$file" banner true) || exit 1
  CFG_DEFAULT_PROFILE=$CFG_PROFILE
  CFG_DEFAULT_PROFILE_REF=$CFG_PROFILE_REF
  CFG_DEFAULT_PROFILE_PATH=$CFG_PROFILE_PATH
}

config_load() {
  [ -f "$POVY_CONFIG_FILE" ] || die "$POVY_CONFIG_FILE not found; run: povy init"
  config_read "$POVY_CONFIG_FILE"
}

POVY_CONFIG_HEADER='# Machine configuration for povy. Never versioned.'

# Rewrites the three answers of povy init. The rest of an existing file, such as
# profile_ref or [[identities]], is kept as it is.
config_write() {
  local name=$1 email=$2 profile=$3 tmp
  tmp=$(mktemp "$POVY_STATE_DIR/config.XXXXXX") || die "cannot write in $POVY_STATE_DIR"
  {
    printf '%s\n' "$POVY_CONFIG_HEADER"
    printf 'name = "%s"\n' "$(toml_escape "$name")"
    printf 'email = "%s"\n' "$(toml_escape "$email")"
    printf 'profile = "%s"\n' "$(toml_escape "$profile")"
    if [ -f "$POVY_CONFIG_FILE" ]; then
      awk -v header="$POVY_CONFIG_HEADER" '
        /^[[:space:]]*\[/ { tables = 1 }
        !tables && /^[[:space:]]*(name|email|profile)[[:space:]]*=/ { next }
        !tables && $0 == header { next }
        { print }
      ' "$POVY_CONFIG_FILE"
    fi
  } >"$tmp"
  if ! (config_read "$tmp"); then
    rm -f "$tmp"
    die "could not update $POVY_CONFIG_FILE; fix it by hand or remove it"
  fi
  install_file "$tmp" "$POVY_CONFIG_FILE" 600
  rm -f "$tmp"
}

env_ensure() {
  if [ ! -e "$POVY_ENV_FILE" ]; then
    (umask 077 && echo '# Secrets for povy. Never versioned.' >"$POVY_ENV_FILE") ||
      die "cannot create $POVY_ENV_FILE"
    info "wrote $POVY_ENV_FILE"
  fi
  chmod 600 "$POVY_ENV_FILE"
}

# Prints the value of a key in one file, or returns 1 when the key has no line. The
# last line wins, as it would in a shell. Surrounding quotes are removed, CRLF is
# tolerated.
env_file_value() {
  local file=$1 key=$2 line value found=1
  [ -f "$file" ] || return 1
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
  done <"$file"
  [ "$found" -eq 0 ] || return 1
  case "$value" in
    \"*\") value=${value#\"} && value=${value%\"} ;;
    \'*\') value=${value#\'} && value=${value%\'} ;;
  esac
  printf '%s' "$value"
}

# Prints the value of a secret of the current context: the first value that is not
# empty, in POVY_ENV_FILE, then POVY_ENV_FALLBACK. Returns 1 when no file has the key.
env_value() {
  local key=$1 file value found=1
  for file in "$POVY_ENV_FILE" ${POVY_ENV_FALLBACK:+"$POVY_ENV_FALLBACK"}; do
    value=$(env_file_value "$file" "$key") || continue
    found=0
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return "$found"
}

# Adds an empty line to POVY_ENV_FILE for each listed key that no file has, and
# creates that file, private, when it needs one. Existing lines stay.
env_seed() {
  local keys=$1 key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    env_value "$key" >/dev/null && continue
    if [ ! -e "$POVY_ENV_FILE" ]; then
      (umask 077 && echo '# Secrets for povy. Never versioned.' >"$POVY_ENV_FILE") ||
        die "cannot create $POVY_ENV_FILE"
      info "wrote $POVY_ENV_FILE"
    fi
    if [ -s "$POVY_ENV_FILE" ] && [ -n "$(tail -c 1 "$POVY_ENV_FILE")" ]; then
      echo >>"$POVY_ENV_FILE"
    fi
    printf '%s=\n' "$key" >>"$POVY_ENV_FILE"
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
