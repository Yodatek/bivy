# shellcheck shell=bash
# Logging, paths, OS loading, terminal input, file installation, mise and yq.
# Everything must run on bash 3.2, the version macOS ships.

POVY_YQ_TOOL="yq@4"
POVY_YQ=""
POVY_BACKUP_DIR=""
POVY_WRITTEN=0
POVY_UNCHANGED=0
POVY_BACKED_UP=0
# The files this run created, one per line: they have no original to back up.
POVY_CREATED=$'\n'
ANSWER=""

# Marks the lines povy owns in a file it shares with the user. Both the shell and
# Git read them as comments. See block_start for named blocks.
POVY_BLOCK_START='# >>> povy >>>'
POVY_BLOCK_END='# <<< povy <<<'

info() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

povy_init_paths() {
  if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    die "HOME is not set to an existing directory"
  fi
  POVY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/povy"
  POVY_CONFIG_FILE="$POVY_CONFIG_DIR/config.toml"
  POVY_ENV_FILE="$POVY_CONFIG_DIR/.env"
  POVY_ENV_SH="$POVY_CONFIG_DIR/env.sh"
  POVY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/povy"
  POVY_PROFILE_DIR="$POVY_STATE_DIR/profile"
  POVY_PROFILE_ROOT="$POVY_PROFILE_DIR"
  POVY_APPLIED="$POVY_STATE_DIR/applied"
  POVY_INTERACTIVE_SH="$POVY_CONFIG_DIR/interactive.sh"
  POVY_BACKUP_ROOT="$POVY_STATE_DIR/backups"
  POVY_MISE_CONF="${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/conf.d/povy.toml"
  POVY_SHIMS_DIR="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
  POVY_LOCAL_BIN="$HOME/.local/bin"
  POVY_GIT_DIR="$POVY_CONFIG_DIR/git"
}

povy_ensure_dirs() {
  mkdir -p "$POVY_CONFIG_DIR" "$POVY_STATE_DIR"
  chmod 700 "$POVY_CONFIG_DIR" "$POVY_STATE_DIR"
}

# The release the engine is on, read from its Git clone: 0.1.0 on a release tag,
# 0.1.0-3-gabc1234 three commits after it, the commit alone before any release.
# Only annotated tags count, as releases are.
povy_version() {
  local version
  version=$(git -C "$POVY_ROOT" describe --match 'v[0-9]*' --always --dirty 2>/dev/null) ||
    version=unknown
  printf '%s\n' "${version#v}"
}

# Kept identical to the copy in bootstrap, which runs before the engine exists.
povy_detect_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux)
      if grep -qi microsoft "${POVY_PROC_VERSION:-/proc/version}" 2>/dev/null; then
        if grep -qiE 'wsl2|microsoft-standard' "${POVY_PROC_VERSION:-/proc/version}"; then
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

povy_load_os() {
  POVY_OS=$(povy_detect_os)
  case "$POVY_OS" in
    darwin | linux | wsl)
      # shellcheck source=/dev/null
      . "$POVY_ROOT/lib/os/$POVY_OS.sh"
      ;;
    windows) die "native Windows is not supported; run povy inside WSL2 (wsl --install)" ;;
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

# Terminal input. POVY_TTY replaces /dev/tty in the test suite.
tty_path() { printf '%s' "${POVY_TTY:-/dev/tty}"; }

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
  # A file this run created has no original to keep.
  case "$POVY_CREATED" in
    *$'\n'"$path"$'\n'*) return 0 ;;
  esac
  if [ -z "$POVY_BACKUP_DIR" ]; then
    POVY_BACKUP_DIR="$POVY_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).$$"
  fi
  case "$path" in
    "$HOME"/*) rel=${path#"$HOME"/} ;;
    *) rel=${path#/} ;;
  esac
  dest="$POVY_BACKUP_DIR/$rel"
  # A file changed twice in one run, such as .bashrc and its two blocks, keeps
  # its first copy: the original.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    return 0
  fi
  (umask 077 && mkdir -p "$(dirname "$dest")") || die "cannot create backup directory for $path"
  if [ "$mode" = follow-link ]; then
    cp -pL "$path" "$dest" || die "cannot back up $path"
  else
    cp -pP "$path" "$dest" || die "cannot back up $path"
  fi
  [ -L "$dest" ] || chmod 600 "$dest"
  POVY_BACKED_UP=$((POVY_BACKED_UP + 1))
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
    POVY_UNCHANGED=$((POVY_UNCHANGED + 1))
    return 0
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    backup_file "$target"
  else
    POVY_CREATED="$POVY_CREATED$target"$'\n'
  fi
  parent=$(dirname "$target")
  mkdir -p "$parent" || die "cannot create $parent"
  tmp=$(mktemp "$parent/.povy.XXXXXX") || die "cannot write in $parent"
  if ! { cat "$src" >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$target"; }; then
    rm -f "$tmp"
    die "cannot write $target"
  fi
  POVY_WRITTEN=$((POVY_WRITTEN + 1))
  info "wrote $target"
}

# The marker lines of a block. A file may hold several blocks, told apart by a name.
block_start() { printf '# >>> povy%s >>>' "${1:+ $1}"; }
block_end() { printf '# <<< povy%s <<<' "${1:+ $1}"; }

# Usage: block_apply FILE BLOCK [top|bottom] [NAME]
# Puts a marked block at the top or at the bottom of a file. At the top, a block
# already there is refreshed in place. At the bottom, it moves to the end, after
# whatever the file sets before it. Content outside the block is not touched, and
# a symlinked dotfile stays a symlink.
block_apply() {
  local file=$1 block=$2 position=${3:-top} start end starts ends current tmp
  start=$(block_start "${4:-}")
  end=$(block_end "${4:-}")
  tmp=$(mktemp "$POVY_STATE_DIR/block.XXXXXX") || die "cannot write in $POVY_STATE_DIR"

  if [ ! -e "$file" ]; then
    printf '%s\n' "$block" >"$file" || die "cannot write $file"
    POVY_CREATED="$POVY_CREATED$file"$'\n'
    rm -f "$tmp"
    POVY_WRITTEN=$((POVY_WRITTEN + 1))
    info "wrote $file"
    return 0
  fi

  starts=$(grep -cxF "$start" "$file") || starts=0
  ends=$(grep -cxF "$end" "$file") || ends=0

  if [ "$starts" -ne "$ends" ] || [ "$starts" -gt 1 ]; then
    rm -f "$tmp"
    die "$file has an incomplete povy block; remove its markers and run povy apply again"
  fi

  if [ "$position" = bottom ]; then
    {
      awk -v s="$start" -v e="$end" '
        $0 == s { on = 1 }
        !on { print }
        $0 == e { on = 0 }
      ' "$file"
      printf '%s\n' "$block"
    } >"$tmp"
    if cmp -s "$tmp" "$file"; then
      rm -f "$tmp"
      POVY_UNCHANGED=$((POVY_UNCHANGED + 1))
      return 0
    fi
  elif [ "$starts" -eq 0 ]; then
    { printf '%s\n' "$block" && cat "$file"; } >"$tmp"
  else
    current=$(awk -v s="$start" -v e="$end" '
      $0 == s { on = 1 }
      on { print }
      $0 == e { on = 0 }
    ' "$file")
    if [ "$current" = "$block" ]; then
      rm -f "$tmp"
      POVY_UNCHANGED=$((POVY_UNCHANGED + 1))
      return 0
    fi
    POVY_BLOCK_TEXT="$block" awk -v s="$start" -v e="$end" '
      $0 == s { on = 1; print ENVIRON["POVY_BLOCK_TEXT"]; next }
      $0 == e { on = 0; next }
      !on { print }
    ' "$file" >"$tmp"
  fi

  backup_file "$file" follow-link
  cat "$tmp" >"$file" || die "cannot write $file"
  rm -f "$tmp"
  POVY_WRITTEN=$((POVY_WRITTEN + 1))
  info "updated $file"
}

# A path as a person reads it, with ~ for the home directory.
tilde_path() {
  # shellcheck disable=SC2088 # A path shown to a person, not expanded.
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# temurin-21.0.13+100000002.0.LTS -> 21.0.13, liberica-javafx-8u492+9 -> 8u492.
short_version() {
  local version=$1
  if [[ "$version" =~ ^[A-Za-z][A-Za-z-]*-([0-9].*)$ ]]; then
    version=${BASH_REMATCH[1]}
  fi
  printf '%s' "${version%%+*}"
}

# mise. MISE_YES avoids prompts when stdin is not a terminal, and running from
# HOME keeps a project's mise.toml in the current directory out of the picture.
mise_find() {
  if command -v mise >/dev/null 2>&1; then
    command -v mise
  elif [ -x "$POVY_LOCAL_BIN/mise" ]; then
    printf '%s\n' "$POVY_LOCAL_BIN/mise"
  else
    return 1
  fi
}

mise_run() {
  local bin
  bin=$(mise_find) || die "mise is not installed; run the povy bootstrap first"
  (cd "$HOME" && MISE_YES=1 "$bin" "$@" </dev/null)
}

# yq comes from mise and parses every TOML file. yq_resolve never installs, so
# that doctor reports the state rather than changing it.
yq_resolve() {
  local dir
  [ -z "$POVY_YQ" ] || return 0
  mise_find >/dev/null || return 1
  dir=$(mise_run where "$POVY_YQ_TOOL" 2>/dev/null) || return 1
  [ -x "$dir/yq" ] || return 1
  POVY_YQ="$dir/yq"
}

yq_ensure() {
  yq_resolve && return 0
  mise_find >/dev/null || die "mise is not installed; run the povy bootstrap first"
  info "installing $POVY_YQ_TOOL with mise"
  mise_run install "$POVY_YQ_TOOL" >/dev/null 2>&1 || die "could not install $POVY_YQ_TOOL with mise"
  yq_resolve || die "$POVY_YQ_TOOL is not available after installation"
}

toml_query() {
  "$POVY_YQ" -p toml -oy "$2" "$1"
}

# One line per array result, fields separated by tabs. Separate `a, b` outputs would
# not do: yq emits all the a values before any b value.
toml_tsv() {
  "$POVY_YQ" -p toml -o tsv "$2" "$1"
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
