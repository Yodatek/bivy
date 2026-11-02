#!/usr/bin/env bats

load helper

setup() {
  sandbox_setup
  load_libs
  STUBS=$BATS_TEST_TMPDIR/stubs
  mkdir -p "$STUBS"
  PROC=$BATS_TEST_TMPDIR/proc
}

detect_with() {
  printf '#!/bin/sh\necho %s\n' "$1" >"$STUBS/uname"
  chmod +x "$STUBS/uname"
  printf '%s\n' "$2" >"$PROC"
  PATH="$STUBS:$PATH" BIVY_PROC_VERSION=$PROC bivy_detect_os
}

@test "systems are told apart" {
  [ "$(detect_with Darwin '')" = darwin ]
  [ "$(detect_with Linux 'Linux version 6.8.0-generic')" = linux ]
  [ "$(detect_with Linux 'Linux version 5.15.90.1-microsoft-standard-WSL2')" = wsl ]
  [ "$(detect_with Linux 'Linux version 4.4.0-19041-Microsoft')" = wsl1 ]
  [ "$(detect_with MINGW64_NT-10.0 '')" = windows ]
  [ "$(detect_with FreeBSD '')" = unsupported ]
}

@test "WSL refuses a home on a Windows drive" {
  . "$BIVY_ROOT/lib/os/wsl.sh"
  HOME=/mnt/c/Users/me run os_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"Windows drive"* ]]
  run os_preflight
  [ "$status" -eq 0 ]
}

@test "WSL warns about a Windows mise" {
  . "$BIVY_ROOT/lib/os/wsl.sh"
  . "$BIVY_ROOT/lib/cmd/doctor.sh"
  command() { printf '/mnt/c/tools/mise\n'; }
  run os_doctor
  [[ "$output" == *"Windows binary"* ]]
}

@test "the login file default differs per system" {
  . "$BIVY_ROOT/lib/os/darwin.sh"
  [ "$(os_bash_login_default)" = .bash_profile ]
  . "$BIVY_ROOT/lib/os/linux.sh"
  [ "$(os_bash_login_default)" = .profile ]
}
