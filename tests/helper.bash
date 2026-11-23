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
  unset CLAUDECODE INSIDE_EMACS TERM_PROGRAM TERMINAL_EMULATOR NO_COLOR CLICOLOR_FORCE
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
  # shellcheck source=lib/team.sh
  . "$POVY_ROOT/lib/team.sh"
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

# Creates a profile repository from a team.toml body, a mise.toml body and files
# given as path=content, the paths relative to the profile, then commits. An empty
# body leaves its file out. A file whose content starts with #! is executable.
make_mise_profile() {
  local dest=$1 team=$2 project=$3 pair path
  shift 3
  mkdir -p "$dest"
  [ -z "$team" ] || printf '%s\n' "$team" >"$dest/team.toml"
  [ -z "$project" ] || printf '%s\n' "$project" >"$dest/mise.toml"
  for pair in "$@"; do
    path=$dest/${pair%%=*}
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "${pair#*=}" >"$path"
    case "${pair#*=}" in
      '#!'*) chmod +x "$path" ;;
    esac
  done
  commit_all "$dest"
}

# A mise.toml body: the template files/t rendered into ~/.out/t in mode 600, and
# each secret given read from the environment variable of the same name.
out_file_project() {
  local secret
  if [ $# -gt 0 ]; then
    echo '[bootstrap.secrets]'
    for secret in "$@"; do
      printf '%s = { env = "%s" }\n' "$secret" "$secret"
    done
  fi
  cat <<'TOML'
[bootstrap.directories."~/.out"]
os = "unix"

[bootstrap.files."~/.out/t"]
os = "unix"
source = "./files/t"
template = true
mode = "0600"
TOML
}

file_mode() {
  # Not a fallback from one syntax to the other: GNU stat reads -f as "file
  # system" and prints before it fails.
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# Hash of every file in the home. Tool installs, the state of mise, caches and the
# Git metadata of the profile clone, which each fetch touches, are left out.
home_fingerprint() {
  (
    cd "$HOME" &&
      find . -type f -not -path './.local/share/mise/*' -not -path './.local/state/mise/*' \
        -not -path './.cache/*' -not -path './Library/Caches/*' \
        -not -path './.local/state/povy/profile/.git/*' -print | LC_ALL=C sort |
      while IFS= read -r f; do
        cksum "$f"
      done
  )
}
