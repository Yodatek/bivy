# shellcheck shell=bash
# Every test runs with HOME in a temporary directory. POVY_TTY never points at the
# real terminal, POVY_LAUNCHCTL never at the real launchctl, and povy refuses to
# run from here if HOME was not redirected.

POVY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_HOME=${REAL_HOME:-$HOME}
export POVY_ROOT REAL_HOME

sandbox_env() {
  local var
  for var in $(compgen -e | grep -E '^(MISE|XDG|POVY)_'); do
    case "$var" in
      POVY_ROOT) ;;
      *) unset "$var" ;;
    esac
  done
  unset ZDOTDIR GIT_DIR GIT_WORK_TREE GIT_CONFIG_GLOBAL
  # The banner keeps quiet in IDEs and agents, the test runner included.
  unset CLAUDECODE INSIDE_EMACS TERM_PROGRAM TERMINAL_EMULATOR NO_COLOR
  export HOME=$1
  export POVY_TTY=/nonexistent/tty
  export SHELL=/bin/sh
  mkdir -p "$HOME"
  stub_launchctl "${1%/*}/launchctl"
}

# Records every call in calls, and keeps PATH in a file instead of the real
# graphical session. getenv of an unset variable prints nothing, like launchctl.
stub_launchctl() {
  local dir=$1
  mkdir -p "$dir"
  rm -f "$dir/calls" "$dir/PATH"
  cat >"$dir/launchctl" <<'STUB'
#!/bin/sh
dir=$(dirname "$0")
printf '%s\n' "$*" >>"$dir/calls"
case "$1 $2" in
  "getenv PATH") if [ -f "$dir/PATH" ]; then cat "$dir/PATH"; fi ;;
  "setenv PATH") printf '%s\n' "$3" >"$dir/PATH" ;;
esac
STUB
  chmod +x "$dir/launchctl"
  export POVY_LAUNCHCTL="$dir/launchctl"
}

# Shares downloads between tests, which keeps fresh homes fast.
sandbox_setup() {
  sandbox_env "$BATS_TEST_TMPDIR/home"
  export MISE_DATA_DIR="$BATS_SUITE_TMPDIR/mise-data"
  export MISE_CACHE_DIR="$BATS_SUITE_TMPDIR/mise-cache"
}

povy() {
  [ "$HOME" != "$REAL_HOME" ] || {
    echo "HOME is the real home, refusing to run" >&2
    return 99
  }
  "$POVY_ROOT/bin/povy" "$@"
}

load_libs() {
  # shellcheck source=lib/common.sh
  . "$POVY_ROOT/lib/common.sh"
  # shellcheck source=lib/config.sh
  . "$POVY_ROOT/lib/config.sh"
  # shellcheck source=lib/profile.sh
  . "$POVY_ROOT/lib/profile.sh"
  # shellcheck source=lib/shell.sh
  . "$POVY_ROOT/lib/shell.sh"
  # shellcheck source=lib/gui.sh
  . "$POVY_ROOT/lib/gui.sh"
  # shellcheck source=lib/git.sh
  . "$POVY_ROOT/lib/git.sh"
  # shellcheck source=lib/packages.sh
  . "$POVY_ROOT/lib/packages.sh"
  povy_init_paths
  povy_load_os
  povy_ensure_dirs
}

write_config() {
  local file=$1 profile=${2:-}
  cat >"$file" <<TOML
name = "Test User"
email = "test@example.org"
profile = "$profile"
TOML
}

# Turns the test profile, or the given directory, into a Git repository.
make_profile_repo() {
  local dest=$1 from=${2:-$POVY_ROOT/tests/fixtures/profile}
  mkdir -p "$dest"
  cp -R "$from/." "$dest/"
  commit_all "$dest"
}

commit_all() {
  git -C "$1" init --quiet -b main 2>/dev/null || true
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.org commit --quiet -m test
}

# Creates a profile from a profile.toml body and templates given as name=content.
make_custom_profile() {
  local dest=$1 toml=$2 pair
  shift 2
  mkdir -p "$dest/files"
  printf '%s\n' "$toml" >"$dest/profile.toml"
  for pair in "$@"; do
    printf '%s\n' "${pair#*=}" >"$dest/files/${pair%%=*}"
  done
  commit_all "$dest"
}

file_mode() {
  # Not a fallback from one syntax to the other: GNU stat reads -f as "file
  # system" and prints before it fails.
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# Hash of everything povy owns in the home; tool installs are left out.
home_fingerprint() {
  (
    cd "$HOME" &&
      find . -type f -not -path './.local/share/mise/*' -not -path './.local/state/mise/*' \
        -not -path './.cache/*' -not -path './Library/*' -print | LC_ALL=C sort |
      while IFS= read -r f; do
        cksum "$f"
      done
  )
}
