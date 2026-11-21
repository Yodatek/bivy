# shellcheck shell=bash
# A profile is an external Git repository holding a profile.toml, which declares
# required secrets, extra mise tools and templates written in the home directory.
# The profile may sit in a subdirectory of the repository, given by profile_path:
# Git works on the clone, POVY_PROFILE_DIR, and everything else reads from
# POVY_PROFILE_ROOT, the directory that holds profile.toml.

PROFILE_SECRETS=""
PROFILE_TOOLS=""
PROFILE_FILES=""
PROFILE_PROMPT=""
PROFILE_BIN=""
PROFILE_SHELL=""
PROFILE_PACKAGES=""

POVY_SECRET_RE='^[A-Za-z_][A-Za-z0-9_]*$'

# Clones the profile on its default branch, or on the branch given. The clone keeps
# the branch it was asked for, so that a new branch, or none, gives a new clone.
profile_clone() {
  local url=$1 branch=${2:-} tmp
  local -a args=()
  [ -z "$branch" ] || args=(--branch "$branch")
  tmp=$(mktemp -d "$POVY_STATE_DIR/profile-clone.XXXXXX") || die "cannot write in $POVY_STATE_DIR"
  if ! git clone --quiet ${args[@]+"${args[@]}"} -- "$url" "$tmp/profile" </dev/null ||
    ! git -C "$tmp/profile" config povy.branch "$branch"; then
    rm -rf "$tmp"
    die "could not clone the profile: $url${branch:+, branch $branch}"
  fi
  rm -rf "$POVY_PROFILE_DIR"
  mv "$tmp/profile" "$POVY_PROFILE_DIR"
  rm -rf "$tmp"
  info "cloned profile $url${branch:+, branch $branch}"
}

# An unreachable remote must not block a machine that already has its profile.
profile_sync() {
  local url=$1 branch=${2:-} current current_branch
  [ -n "$url" ] || return 0
  current=$(git -C "$POVY_PROFILE_DIR" remote get-url origin 2>/dev/null) || current=""
  current_branch=$(git -C "$POVY_PROFILE_DIR" config --get povy.branch 2>/dev/null) || current_branch=""
  if [ "$current" != "$url" ] || [ "$current_branch" != "$branch" ]; then
    profile_clone "$url" "$branch"
  elif ! git -C "$POVY_PROFILE_DIR" pull --quiet --ff-only </dev/null; then
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

# Succeeds when a directory resolves, symlinks followed, to a place inside another.
path_within() {
  local real base
  real=$(cd -P "$1" 2>/dev/null && pwd) || return 1
  base=$(cd -P "$2" 2>/dev/null && pwd) || return 1
  case "$real/" in
    "$base/"*) return 0 ;;
  esac
  return 1
}

# Rejects a template that resolves outside the profile through a symlink.
profile_check_source() {
  local rel=$1 path
  path="$POVY_PROFILE_ROOT/$rel"
  [ -f "$path" ] && [ ! -L "$path" ] || die "profile template not found: $rel"
  path_within "$(dirname "$path")" "$POVY_PROFILE_ROOT" || die "profile template is outside the profile: $rel"
}

# Rejects a directory that is missing or resolves outside the profile.
profile_check_dir() {
  local rel=$1 path
  path="$POVY_PROFILE_ROOT/$rel"
  [ -d "$path" ] || die "profile directory not found: $rel"
  path_within "$path" "$POVY_PROFILE_ROOT" || die "profile directory is outside the profile: $rel"
}

# Fills PROFILE_SECRETS (one per line), PROFILE_TOOLS (name<TAB>version) and
# PROFILE_FILES (source<TAB>target), from the clone or from its subdirectory given
# as the second argument. Stays empty when no profile is configured.
profile_load() {
  local url=$1 subdir=${2:-} file raw secret source target count seen=0 tag
  PROFILE_SECRETS=""
  PROFILE_TOOLS=""
  PROFILE_FILES=""
  PROFILE_PROMPT=""
  PROFILE_BIN=""
  PROFILE_SHELL=""
  PROFILE_PACKAGES=""
  POVY_PROFILE_ROOT=$POVY_PROFILE_DIR
  [ -n "$url" ] || return 0
  if [ -n "$subdir" ]; then
    POVY_PROFILE_ROOT="$POVY_PROFILE_DIR/$subdir"
    [ -d "$POVY_PROFILE_ROOT" ] || die "the profile repository has no directory $subdir: $url"
    path_within "$POVY_PROFILE_ROOT" "$POVY_PROFILE_DIR" || die "profile_path is outside the profile: $subdir"
  fi
  file="$POVY_PROFILE_ROOT/profile.toml"
  [ -f "$file" ] || die "the profile has no profile.toml: $url${subdir:+, path $subdir}"

  raw=$(toml_query "$file" '(.secrets.required // [])[]') || die "$file is not valid TOML"
  while IFS= read -r secret; do
    [ -n "$secret" ] || continue
    [[ "$secret" =~ $POVY_SECRET_RE ]] || die "$file: invalid secret name: $secret"
    PROFILE_SECRETS="$PROFILE_SECRETS$secret"$'\n'
  done <<<"$raw"

  PROFILE_TOOLS=$(toml_tools "$file") || exit 1
  PROFILE_PROMPT=$(toml_prompt "$file") || exit 1
  PROFILE_PACKAGES=$(toml_packages "$file") || exit 1

  # bin: a directory of commands put on PATH, read in place from the clone.
  PROFILE_BIN=$(toml_string "$file" bin) || exit 1
  PROFILE_BIN=${PROFILE_BIN%/}
  if [ -n "$PROFILE_BIN" ]; then
    valid_relative_path "$PROFILE_BIN" || die "$file: invalid bin: $PROFILE_BIN"
    profile_check_dir "$PROFILE_BIN"
  fi

  # shell: files that interactive shells source, for aliases and functions.
  tag=$(toml_query "$file" '(.shell // []) | tag') || die "$file is not valid TOML"
  [ "$tag" = '!!seq' ] || die "$file: shell must be a list of files"
  tag=$(toml_query "$file" '[(.shell // [])[] | tag | select(. != "!!str")] | length') ||
    die "$file is not valid TOML"
  [ "$tag" = 0 ] || die "$file: shell must be a list of files"
  raw=$(toml_query "$file" '(.shell // [])[]') || die "$file is not valid TOML"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    valid_relative_path "$source" || die "$file: invalid shell file: $source"
    profile_check_source "$source"
    PROFILE_SHELL="$PROFILE_SHELL$source"$'\n'
  done <<<"$raw"

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
    export POVY_TPL_name="$CFG_NAME" POVY_TPL_email="$CFG_EMAIL" POVY_TPL_home="$HOME"
    while IFS= read -r secret; do
      [ -n "$secret" ] || continue
      export "POVY_TPL_$secret=$(env_value "$secret")"
    done <<<"$PROFILE_SECRETS"
    # shellcheck disable=SC2016
    awk '
      {
        rest = $0
        out = ""
        while (match(rest, /\{\{[A-Za-z_][A-Za-z0-9_]*\}\}/)) {
          key = substr(rest, RSTART + 2, RLENGTH - 4)
          if (!(("POVY_TPL_" key) in ENVIRON)) {
            print "unknown placeholder {{" key "}} in " FILENAME > "/dev/stderr"
            exit 3
          }
          out = out substr(rest, 1, RSTART - 1) ENVIRON["POVY_TPL_" key]
          rest = substr(rest, RSTART + RLENGTH)
        }
        print out rest
      }
    ' "$src" >"$dst"
  )
}
