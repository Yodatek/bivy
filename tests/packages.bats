#!/usr/bin/env bats
# [packages], with fake package managers that record their calls in $STATE/calls
# and keep what they installed in $STATE/<manager>. Nothing real is installed.

load helper

setup() {
  sandbox_setup
  load_libs
  STUBS=$BATS_TEST_TMPDIR/stubs
  STATE=$BATS_TEST_TMPDIR/state
  mkdir -p "$STUBS" "$STATE"
  touch "$STATE/formula" "$STATE/cask" "$STATE/dpkg" "$STATE/rpm"
  export STATE
  cat >"$STUBS/brew" <<'SH'
#!/bin/sh
echo "brew $*" >>"$STATE/calls"
[ -z "${BREW_FAIL:-}" ] || exit 1
case "$1 $2" in
  "list --formula") cat "$STATE/formula" ;;
  "list --cask") cat "$STATE/cask" ;;
  "install --cask") shift 2; for p in "$@"; do echo "${p##*/}" >>"$STATE/cask"; done ;;
  install*) shift; for p in "$@"; do echo "${p##*/}" >>"$STATE/formula"; done ;;
esac
SH
  cat >"$STUBS/apt-get" <<'SH'
#!/bin/sh
echo "apt-get $*" >>"$STATE/calls"
[ "$1" = install ] || exit 0
shift 2
for p in "$@"; do echo "$p" >>"$STATE/dpkg"; done
SH
  cat >"$STUBS/dpkg-query" <<'SH'
#!/bin/sh
for last; do :; done
grep -qxF "$last" "$STATE/dpkg" && printf 'ii ' || exit 1
SH
  cat >"$STUBS/dnf" <<'SH'
#!/bin/sh
echo "dnf $*" >>"$STATE/calls"
shift 2
for p in "$@"; do echo "$p" >>"$STATE/rpm"; done
SH
  cat >"$STUBS/rpm" <<'SH'
#!/bin/sh
grep -qxF "$2" "$STATE/rpm"
SH
  cat >"$STUBS/sudo" <<'SH'
#!/bin/sh
echo "sudo $*" >>"$STATE/calls"
[ "$1" != -n ] || shift
exec "$@"
SH
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
}

# Only the managers named are present here.
only_managers() {
  PRESENT=" $* "
  packages_command() {
    case "$PRESENT" in
      *" $1 "*) printf '%s\n' "$STUBS/$1" ;;
    esac
  }
}

calls() {
  cat "$STATE/calls" 2>/dev/null || true
}

@test "missing formulas and casks are installed, installed ones are left, a second run does nothing" {
  only_managers brew cask
  echo jq >"$STATE/formula"
  PROFILE_PACKAGES=$'brew\tjq\nbrew\tpodman\nbrew\towner/tap/tool\ncask\titerm2'
  run packages_apply
  [ "$status" -eq 0 ]
  calls | grep -qxF "brew install owner/tap/tool podman"
  calls | grep -qxF "brew install --cask iterm2"
  ! calls | grep -q "install jq"
  rm "$STATE/calls"
  run packages_apply
  [ "$status" -eq 0 ]
  ! calls | grep -q install
}

@test "apt goes through sudo, without waiting for a password when there is no terminal" {
  only_managers apt
  echo git >"$STATE/dpkg"
  PROFILE_PACKAGES=$'apt\tgit\napt\tpodman'
  run packages_apply
  [ "$status" -eq 0 ]
  calls | grep -qxF "sudo -n apt-get install -y podman"
  ! calls | grep -q "install -y git"
}

@test "dnf installs what rpm does not know" {
  only_managers dnf
  PROFILE_PACKAGES=$'dnf\tpodman'
  run packages_apply
  calls | grep -qxF "sudo -n dnf install -y podman"
}

@test "the profile and the machine lists add up" {
  only_managers brew
  PROFILE_PACKAGES=$'brew\tpodman'
  CFG_PACKAGES=$'brew\tansible\nbrew\tpodman'
  run packages_apply
  calls | grep -qxF "brew install ansible podman"
}

@test "lists for absent managers are skipped; none at all is reported" {
  only_managers apt
  PROFILE_PACKAGES=$'brew\tpodman\napt\tpodman'
  run packages_apply
  ! calls | grep -q "^brew"
  only_managers brew
  PROFILE_PACKAGES=$'apt\tpodman\ndnf\tpodman'
  run packages_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"no package manager here for: podman"* ]]
}

@test "a failed install is a warning, and apply goes on" {
  only_managers brew
  PROFILE_PACKAGES=$'brew\tpodman'
  BREW_FAIL=1 run packages_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not install with brew: podman"* ]]
}

@test "invalid [packages] are refused" {
  local body config=$BATS_TEST_TMPDIR/c.toml
  for body in 'packages = ["podman"]' $'[packages]\npacman = ["podman"]' $'[packages]\nbrew = "podman"' \
    $'[packages]\nbrew = [1]' $'[packages]\nbrew = ["bad name"]'; do
    write_config "$config"
    printf '%s\n' "$body" >>"$config"
    run povy init --config "$config"
    [ "$status" -ne 0 ] || {
      echo "accepted: $body"
      return 1
    }
  done
}

@test "doctor reports the packages that are missing, and counts those of managers here" {
  local config=$BATS_TEST_TMPDIR/c.toml
  rm "$STUBS/dnf"
  ! command -v dnf >/dev/null || skip "dnf is installed here"
  write_config "$config"
  printf '[packages]\nbrew = ["podman"]\ndnf = ["podman", "git"]\n' >>"$config"
  povy init --config "$config"
  run povy doctor
  [[ "$output" == *"[FAIL] packages not installed: brew:podman; run: povy apply"* ]]
  echo podman >"$STATE/formula"
  run povy doctor
  [[ "$output" == *"[ok]   packages: 1 installed with brew"* ]]
}
