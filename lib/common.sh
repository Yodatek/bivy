# shellcheck shell=bash
# Logging, paths, OS loading, terminal input, file installation, mise and yq.
# Everything must run on bash 3.2, the version macOS ships.

BIVY_YQ_TOOL="yq@4"
BIVY_YQ=""
BIVY_BACKUP_DIR=""
BIVY_WRITTEN=0
BIVY_UNCHANGED=0
BIVY_BACKED_UP=0
ANSWER=""

info() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

bivy_init_paths() {
  if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    die "HOME is not set to an existing directory"
  fi
  BIVY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bivy"
  BIVY_CONFIG_FILE="$BIVY_CONFIG_DIR/config.toml"
  BIVY_ENV_FILE="$BIVY_CONFIG_DIR/.env"
  BIVY_ENV_SH="$BIVY_CONFIG_DIR/env.sh"
  BIVY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bivy"
  BIVY_PROFILE_DIR="$BIVY_STATE_DIR/profile"
  BIVY_BACKUP_ROOT="$BIVY_STATE_DIR/backups"
  BIVY_MISE_CONF="${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/conf.d/bivy.toml"
  BIVY_SHIMS_DIR="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
  BIVY_LOCAL_BIN="$HOME/.local/bin"
}

bivy_ensure_dirs() {
  mkdir -p "$BIVY_CONFIG_DIR" "$BIVY_STATE_DIR"
  chmod 700 "$BIVY_CONFIG_DIR" "$BIVY_STATE_DIR"
}

# Kept identical to the copy in bootstrap, which runs before the engine exists.
bivy_detect_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux)
      if grep -qi microsoft "${BIVY_PROC_VERSION:-/proc/version}" 2>/dev/null; then
        if grep -qiE 'wsl2|microsoft-standard' "${BIVY_PROC_VERSION:-/proc/version}"; then
          echo wsl
        else
          echo wsl1
        fi
      else
        echo linux
      fi
      ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) echo windows ;;
    *) echo unsupported ;;
  esac
}

bivy_load_os() {
  BIVY_OS=$(bivy_detect_os)
  case "$BIVY_OS" in
    darwin | linux | wsl)
      # shellcheck source=/dev/null
      . "$BIVY_ROOT/lib/os/$BIVY_OS.sh"
      ;;
    windows) die "native Windows is not supported; run bivy inside WSL2 (wsl --install)" ;;
    wsl1) die "WSL1 is not supported; convert the distribution with: wsl --set-version <distro> 2" ;;
    *) die "unsupported system: $(uname -s)" ;;
  esac
}

has_control_chars() {
  case "$1" in
    *[[:cntrl:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Terminal input. BIVY_TTY replaces /dev/tty in the test suite.
tty_path() { printf '%s' "${BIVY_TTY:-/dev/tty}"; }

tty_available() {
  (: <"$(tty_path)") 2>/dev/null
}

# Reads from fd 3, which the caller opens on the terminal. The answer is left in
# ANSWER so that sequential reads share one file offset.
tty_ask() {
  local label=$1 default=${2:-}
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r ANSWER <&3 || die "no answer on the terminal"
  ANSWER=${ANSWER%$'\r'}
  [ -n "$ANSWER" ] || ANSWER=$default
}

backup_file() {
  local path=$1 mode=${2:-keep-link} rel dest
  if [ -z "$BIVY_BACKUP_DIR" ]; then
    BIVY_BACKUP_DIR="$BIVY_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).$$"
  fi
  case "$path" in
    "$HOME"/*) rel=${path#"$HOME"/} ;;
    *) rel=${path#/} ;;
  esac
  dest="$BIVY_BACKUP_DIR/$rel"
  (umask 077 && mkdir -p "$(dirname "$dest")") || die "cannot create backup directory for $path"
  if [ "$mode" = follow-link ]; then
    cp -pL "$path" "$dest" || die "cannot back up $path"
  else
    cp -pP "$path" "$dest" || die "cannot back up $path"
  fi
  [ -L "$dest" ] || chmod 600 "$dest"
  BIVY_BACKED_UP=$((BIVY_BACKED_UP + 1))
  info "backed up $path"
}

# Atomically installs src at target. An identical file is left alone, apart from
# its mode; anything else that would be replaced is backed up first.
install_file() {
  local src=$1 target=$2 mode=$3 parent tmp
  if [ -d "$target" ] && [ ! -L "$target" ]; then
    die "$target is a directory, refusing to replace it"
  fi
  if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$src" "$target"; then
    [ "$(os_file_mode "$target")" = "$mode" ] || chmod "$mode" "$target"
    BIVY_UNCHANGED=$((BIVY_UNCHANGED + 1))
    return 0
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    backup_file "$target"
  fi
  parent=$(dirname "$target")
  mkdir -p "$parent" || die "cannot create $parent"
  tmp=$(mktemp "$parent/.bivy.XXXXXX") || die "cannot write in $parent"
  if ! { cat "$src" >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$target"; }; then
    rm -f "$tmp"
    die "cannot write $target"
  fi
  BIVY_WRITTEN=$((BIVY_WRITTEN + 1))
  info "wrote $target"
}

# mise. MISE_YES avoids prompts when stdin is not a terminal, and running from
# HOME keeps a project's mise.toml in the current directory out of the picture.
mise_find() {
  if command -v mise >/dev/null 2>&1; then
    command -v mise
  elif [ -x "$BIVY_LOCAL_BIN/mise" ]; then
    printf '%s\n' "$BIVY_LOCAL_BIN/mise"
  else
    return 1
  fi
}

mise_run() {
  local bin
  bin=$(mise_find) || die "mise is not installed; run the bivy bootstrap first"
  (cd "$HOME" && MISE_YES=1 "$bin" "$@" </dev/null)
}

# yq comes from mise and parses every TOML file. yq_resolve never installs, so
# that doctor reports the state rather than changing it.
yq_resolve() {
  local dir
  [ -z "$BIVY_YQ" ] || return 0
  mise_find >/dev/null || return 1
  dir=$(mise_run where "$BIVY_YQ_TOOL" 2>/dev/null) || return 1
  [ -x "$dir/yq" ] || return 1
  BIVY_YQ="$dir/yq"
}

yq_ensure() {
  yq_resolve && return 0
  mise_find >/dev/null || die "mise is not installed; run the bivy bootstrap first"
  info "installing $BIVY_YQ_TOOL with mise"
  mise_run install "$BIVY_YQ_TOOL" >/dev/null 2>&1 || die "could not install $BIVY_YQ_TOOL with mise"
  yq_resolve || die "$BIVY_YQ_TOOL is not available after installation"
}

toml_query() {
  "$BIVY_YQ" -p toml -oy "$2" "$1"
}

# One line per array result, fields separated by tabs. Separate `a, b` outputs would
# not do: yq emits all the a values before any b value.
toml_tsv() {
  "$BIVY_YQ" -p toml -o tsv "$2" "$1"
}

# Prints a top-level string, or nothing when the key is absent.
toml_string() {
  local file=$1 key=$2 tag
  tag=$(toml_query "$file" "(.$key // \"\") | tag") || die "$file is not valid TOML"
  [ "$tag" = '!!str' ] || die "$file: $key must be a string"
  toml_query "$file" "(.$key // \"\")"
}

toml_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}
