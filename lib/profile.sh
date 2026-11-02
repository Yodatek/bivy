# shellcheck shell=bash
# A profile is an external Git repository holding a profile.toml, which declares
# required secrets, extra mise tools and templates written in the home directory.

PROFILE_SECRETS=""
PROFILE_TOOLS=""
PROFILE_FILES=""

BIVY_SECRET_RE='^[A-Za-z_][A-Za-z0-9_]*$'

profile_clone() {
  local url=$1 tmp
  tmp=$(mktemp -d "$BIVY_STATE_DIR/profile-clone.XXXXXX") || die "cannot write in $BIVY_STATE_DIR"
  if ! git clone --quiet -- "$url" "$tmp/profile" </dev/null; then
    rm -rf "$tmp"
    die "could not clone the profile: $url"
  fi
  rm -rf "$BIVY_PROFILE_DIR"
  mv "$tmp/profile" "$BIVY_PROFILE_DIR"
  rm -rf "$tmp"
  info "cloned profile $url"
}

# An unreachable remote must not block a machine that already has its profile.
profile_sync() {
  local url=$1 current
  [ -n "$url" ] || return 0
  current=$(git -C "$BIVY_PROFILE_DIR" remote get-url origin 2>/dev/null) || current=""
  if [ "$current" != "$url" ]; then
    profile_clone "$url"
  elif ! git -C "$BIVY_PROFILE_DIR" pull --quiet --ff-only </dev/null; then
    warn "could not update the profile, using the local copy"
  fi
}

valid_relative_path() {
  local path=$1
  case "$path" in
    '' | /* | '~'* | */) return 1 ;;
  esac
  case "/$path/" in
    */../* | */./*) return 1 ;;
  esac
  ! has_control_chars "$path"
}

# Rejects a template that resolves outside the profile through a symlink.
profile_check_source() {
  local rel=$1 path dir
  path="$BIVY_PROFILE_DIR/$rel"
  [ -f "$path" ] && [ ! -L "$path" ] || die "profile template not found: $rel"
  dir=$(cd -P "$(dirname "$path")" && pwd) || die "profile template not found: $rel"
  case "$dir/" in
    "$(cd -P "$BIVY_PROFILE_DIR" && pwd)/"*) ;;
    *) die "profile template is outside the profile: $rel" ;;
  esac
}

# Fills PROFILE_SECRETS (one per line), PROFILE_TOOLS (name<TAB>version) and
# PROFILE_FILES (source<TAB>target). Stays empty when no profile is configured.
profile_load() {
  local url=$1 file raw secret source target count seen=0
  PROFILE_SECRETS=""
  PROFILE_TOOLS=""
  PROFILE_FILES=""
  [ -n "$url" ] || return 0
  file="$BIVY_PROFILE_DIR/profile.toml"
  [ -f "$file" ] || die "the profile has no profile.toml: $url"

  raw=$(toml_query "$file" '(.secrets.required // [])[]') || die "$file is not valid TOML"
  while IFS= read -r secret; do
    [ -n "$secret" ] || continue
    [[ "$secret" =~ $BIVY_SECRET_RE ]] || die "$file: invalid secret name: $secret"
    PROFILE_SECRETS="$PROFILE_SECRETS$secret"$'\n'
  done <<<"$raw"

  PROFILE_TOOLS=$(toml_tools "$file") || exit 1

  count=$(toml_query "$file" '(.files // []) | length') || die "$file is not valid TOML"
  raw=$(toml_tsv "$file" '(.files // [])[] | [(.source // ""), (.target // "")]') ||
    die "$file is not valid TOML"
  while IFS=$'\t' read -r source target; do
    [ -n "$source$target" ] || continue
    valid_relative_path "$source" || die "$file: invalid source: $source"
    valid_relative_path "$target" || die "$file: target must stay in the home directory: $target"
    profile_check_source "$source"
    PROFILE_FILES="$PROFILE_FILES$source"$'\t'"$target"$'\n'
    seen=$((seen + 1))
  done <<<"$raw"
  [ "$seen" -eq "$count" ] || die "$file: malformed [[files]] entry"
}

# Replaces {{name}}, {{email}}, {{home}} and {{SECRET}}. Text that does not look
# like a placeholder is copied as is, so other template syntaxes pass through.
# Values travel through the environment of awk, never through its arguments.
template_render() {
  local src=$1 dst=$2 secret
  (
    export BIVY_TPL_name="$CFG_NAME" BIVY_TPL_email="$CFG_EMAIL" BIVY_TPL_home="$HOME"
    while IFS= read -r secret; do
      [ -n "$secret" ] || continue
      export "BIVY_TPL_$secret=$(env_value "$secret")"
    done <<<"$PROFILE_SECRETS"
    # shellcheck disable=SC2016
    awk '
      {
        rest = $0
        out = ""
        while (match(rest, /\{\{[A-Za-z_][A-Za-z0-9_]*\}\}/)) {
          key = substr(rest, RSTART + 2, RLENGTH - 4)
          if (!(("BIVY_TPL_" key) in ENVIRON)) {
            print "unknown placeholder {{" key "}} in " FILENAME > "/dev/stderr"
            exit 3
          }
          out = out substr(rest, 1, RSTART - 1) ENVIRON["BIVY_TPL_" key]
          rest = substr(rest, RSTART + RLENGTH)
        }
        print out rest
      }
    ' "$src" >"$dst"
  )
}
