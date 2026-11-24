# shellcheck shell=bash
# A profile is a team's Git repository in mise's own format:
#   team.toml  included by mise in every directory, through povy's conf.d file:
#              tools, [env], [shell_alias], [vars]
#   mise.toml  the project that mise bootstrap applies: packages, secrets, files,
#              shell activation, with the files it refers to next to it. mise
#              ignores its [_] table, where [_.povy] holds what povy does itself:
#              bin, a directory of commands that povy puts on every PATH, and
#              [_.povy.windows], for what mise does not do on Windows
# povy clones it on a ref, keeps it up to date and points mise at it. Git works on
# the clone, POVY_PROFILE_DIR; the rest reads POVY_PROFILE_ROOT, which profile_path
# can set to a directory of the repository.

PROFILE_TEAM=""
PROFILE_PROJECT=""
PROFILE_BIN=""

# Clones the profile, then checks out the ref given: a branch, a tag or a commit.
# The clone keeps the ref it was asked for, so that another ref, or none, gives a
# new clone.
profile_clone() {
  local url=$1 ref=${2:-} tmp
  tmp=$(mktemp -d "$POVY_STATE_DIR/profile-clone.XXXXXX") || die "cannot write in $POVY_STATE_DIR"
  if ! git clone --quiet -- "$url" "$tmp/profile" </dev/null ||
    { [ -n "$ref" ] && ! git -C "$tmp/profile" checkout --quiet "$ref" -- </dev/null; } ||
    ! git -C "$tmp/profile" config povy.ref "$ref"; then
    rm -rf "$tmp"
    die "could not clone the profile: $url${ref:+, ref $ref}"
  fi
  rm -rf "$POVY_PROFILE_DIR"
  mkdir -p "${POVY_PROFILE_DIR%/*}" || die "cannot write in ${POVY_PROFILE_DIR%/*}"
  mv "$tmp/profile" "$POVY_PROFILE_DIR"
  rm -rf "$tmp"
  info "cloned profile $url${ref:+, ref $ref}"
}

# A branch follows its remote; a tag is looked up again, as it may have moved; a
# commit stays. An unreachable remote must not block a machine that already has
# its profile.
profile_sync() {
  local url=$1 ref=${2:-} current current_ref
  [ -n "$url" ] || return 0
  current=$(git -C "$POVY_PROFILE_DIR" remote get-url origin 2>/dev/null) || current=""
  current_ref=$(git -C "$POVY_PROFILE_DIR" config --get povy.ref 2>/dev/null) || current_ref=""
  if [ "$current" != "$url" ] || [ "$current_ref" != "$ref" ] ||
    ! git -C "$POVY_PROFILE_DIR" config --get povy.ref >/dev/null 2>&1; then
    profile_clone "$url" "$ref"
  elif git -C "$POVY_PROFILE_DIR" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    git -C "$POVY_PROFILE_DIR" pull --quiet --ff-only </dev/null ||
      warn "could not update the profile, using the local copy"
  elif ! { git -C "$POVY_PROFILE_DIR" fetch --quiet --tags --force origin </dev/null &&
    git -C "$POVY_PROFILE_DIR" checkout --quiet "$ref" -- </dev/null; }; then
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

# Prints the path of a profile file when it is a regular file inside the profile.
profile_file() {
  local name=$1 path
  path="$POVY_PROFILE_ROOT/$name"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "the profile's $name must be a regular file"
  printf '%s' "$path"
}

# Sets POVY_PROFILE_ROOT, PROFILE_TEAM and PROFILE_PROJECT from the clone, or from
# its subdirectory given as the second argument. They stay empty without a profile.
profile_load() {
  local url=$1 subdir=${2:-}
  PROFILE_TEAM=""
  PROFILE_PROJECT=""
  PROFILE_BIN=""
  POVY_PROFILE_ROOT=$POVY_PROFILE_DIR
  [ -n "$url" ] || return 0
  if [ -n "$subdir" ]; then
    POVY_PROFILE_ROOT="$POVY_PROFILE_DIR/$subdir"
    [ -d "$POVY_PROFILE_ROOT" ] || die "the profile repository has no directory $subdir: $url"
    path_within "$POVY_PROFILE_ROOT" "$POVY_PROFILE_DIR" || die "profile_path is outside the profile: $subdir"
  fi
  PROFILE_TEAM=$(profile_file team.toml) || exit 1
  PROFILE_PROJECT=$(profile_file mise.toml) || exit 1
  if [ -z "$PROFILE_TEAM$PROFILE_PROJECT" ]; then
    if [ -f "$POVY_PROFILE_ROOT/profile.toml" ]; then
      die "the profile is in the povy 0.1 format, profile.toml; convert it to team.toml and mise.toml, as _samples/profile shows: $url"
    fi
    die "the profile has neither team.toml nor mise.toml: $url${subdir:+, path $subdir}"
  fi
  [ -z "$PROFILE_PROJECT" ] || profile_load_povy "$PROFILE_PROJECT"
}

# Reads [_.povy] in the profile's mise.toml. bin is read in place from the clone,
# so a command added to the profile is there after the next apply.
profile_load_povy() {
  local file=$1 tag bin
  tag=$(toml_query "$file" '(._.povy // {}) | tag') || die "$file is not valid TOML"
  [ "$tag" = '!!map' ] || die "$file: _.povy must be a table: [_.povy]"
  bin=$(toml_string "$file" '_.povy.bin') || exit 1
  bin=${bin%/}
  [ -n "$bin" ] || return 0
  valid_relative_path "$bin" || die "$file: invalid _.povy.bin: $bin"
  [ -d "$POVY_PROFILE_ROOT/$bin" ] || die "$file: _.povy.bin is not a directory of the profile: $bin"
  path_within "$POVY_PROFILE_ROOT/$bin" "$POVY_PROFILE_ROOT" || die "$file: _.povy.bin is outside the profile: $bin"
  PROFILE_BIN="$POVY_PROFILE_ROOT/$bin"
}
