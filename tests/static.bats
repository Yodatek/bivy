#!/usr/bin/env bats

load helper

sources() {
  (cd "$BIVY_ROOT" && find bootstrap bin lib -type f)
}

@test "HOME is never assigned" {
  local hits
  hits=$(cd "$BIVY_ROOT" && sources | xargs grep -nE '(^|[^A-Z_])(export +)?HOME=' | grep -vF 'HOME="$HOME"' || true)
  [ -z "$hits" ]
}

@test "scripts stick to bash 3.2: no associative arrays, mapfile or case modification" {
  local hits
  hits=$(cd "$BIVY_ROOT" && sources | xargs grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[a-zA-Z_]+(,,|\^\^)' || true)
  [ -z "$hits" ]
}

@test ".env is never sourced" {
  local hits
  hits=$(cd "$BIVY_ROOT" && sources | xargs grep -nE '^\s*(\.|source) .*ENV_FILE' || true)
  [ -z "$hits" ]
}

@test "the OS adapters define the same functions" {
  local os
  for os in darwin linux; do
    grep -q '^os_file_mode()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_bash_login_default()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_preflight()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_doctor()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_file()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_render()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_activate()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_session_state()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_cpu_load()' "$BIVY_ROOT/lib/os/$os.sh"
    grep -q '^os_memory()' "$BIVY_ROOT/lib/os/$os.sh"
  done
}

@test "shellcheck is clean" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  cd "$BIVY_ROOT"
  run shellcheck -x bootstrap bin/bivy lib/*.sh lib/os/*.sh lib/cmd/*.sh tests/helper.bash .githooks/pre-push scripts/banner-image
  echo "$output"
  [ "$status" -eq 0 ]
}
