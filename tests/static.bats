#!/usr/bin/env bats

load helper

sources() {
  (cd "$POVY_ROOT" && find bootstrap bin lib -type f)
}

@test "HOME is never assigned" {
  local hits
  hits=$(cd "$POVY_ROOT" && sources | xargs grep -nE '(^|[^A-Z_])(export +)?HOME=' | grep -vF 'HOME="$HOME"' || true)
  [ -z "$hits" ]
}

@test "scripts stick to bash 3.2: no associative arrays, mapfile or case modification" {
  local hits
  hits=$(cd "$POVY_ROOT" && sources | xargs grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[a-zA-Z_]+(,,|\^\^)' || true)
  [ -z "$hits" ]
}

@test ".env is never sourced" {
  local hits
  hits=$(cd "$POVY_ROOT" && sources | xargs grep -nE '^\s*(\.|source) .*ENV_FILE' || true)
  [ -z "$hits" ]
}

@test "the OS adapters define the same functions" {
  local os
  for os in darwin linux; do
    grep -q '^os_file_mode()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_bash_login_default()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_preflight()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_doctor()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_file()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_render()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_activate()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_gui_session_state()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_cpu_load()' "$POVY_ROOT/lib/os/$os.sh"
    grep -q '^os_memory()' "$POVY_ROOT/lib/os/$os.sh"
  done
}

@test "shellcheck is clean" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  cd "$POVY_ROOT"
  run shellcheck -x bootstrap bin/povy lib/*.sh lib/os/*.sh lib/cmd/*.sh tests/helper.bash .githooks/pre-push scripts/banner-image
  echo "$output"
  [ "$status" -eq 0 ]
}
