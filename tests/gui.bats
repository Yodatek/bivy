#!/usr/bin/env bats
# PATH of graphical apps. Both adapters are tested on any system: they only write
# files and call launchctl through the recording stub.

load helper

setup() {
  sandbox_setup
  load_libs
  shell_write_env
  STUB_DIR=${BIVY_LAUNCHCTL%/*}
  SHIMS=$BIVY_SHIMS_DIR
  LOCAL_BIN=$HOME/.local/bin
}

use_darwin() {
  . "$BIVY_ROOT/lib/os/darwin.sh"
  PLIST=$HOME/Library/LaunchAgents/bivy.env.plist
}

use_linux() {
  . "$BIVY_ROOT/lib/os/linux.sh"
  ENV_D=$HOME/.config/environment.d/50-bivy.conf
}

setenv_calls() {
  grep -c '^setenv ' "$STUB_DIR/calls" || true
}

need_plutil() {
  command -v plutil >/dev/null || skip "plutil is only on macOS"
}

@test "macOS: the agent is written, and the PATH is set now with the shims first" {
  use_darwin
  run gui_apply
  [ "$status" -eq 0 ]
  [ -f "$PLIST" ]
  [ "$(file_mode "$PLIST")" = 644 ]
  [ "$(cat "$STUB_DIR/PATH")" = "$SHIMS:$LOCAL_BIN:/usr/bin:/bin:/usr/sbin:/sbin" ]
  [[ "$output" == *"graphical apps started from now on"* ]]
}

@test "macOS: an existing PATH is kept, and a second run sets nothing" {
  use_darwin
  echo "/opt/extra/bin:/usr/bin:/bin" >"$STUB_DIR/PATH"
  gui_apply
  [ "$(cat "$STUB_DIR/PATH")" = "$SHIMS:$LOCAL_BIN:/opt/extra/bin:/usr/bin:/bin" ]
  [ "$(setenv_calls)" -eq 1 ]
  BIVY_WRITTEN=0
  gui_apply
  [ "$(setenv_calls)" -eq 1 ]
  [ "$BIVY_WRITTEN" -eq 0 ]
}

@test "macOS: a launchctl that fails is a warning, not an error" {
  use_darwin
  BIVY_LAUNCHCTL=false
  run gui_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"next login"* ]]
  [ -f "$PLIST" ]
}

@test "macOS: the plist is valid and its program sets the PATH from env.sh" {
  need_plutil
  use_darwin
  gui_apply
  plutil -lint "$PLIST"
  [ "$(plutil -extract Label raw -o - "$PLIST")" = bivy.env ]
  [ "$(plutil -extract RunAtLoad raw -o - "$PLIST")" = true ]
  [ "$(plutil -extract ProgramArguments.4 raw -o - "$PLIST")" = /bin/launchctl ]
  local script
  script=$(plutil -extract ProgramArguments.2 raw -o - "$PLIST")
  [[ "$script" == *'"$HOME/.config/bivy/env.sh"'* ]]

  # What launchd would run at login, with the stub in place of /bin/launchctl.
  rm -f "$STUB_DIR/PATH"
  env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c "$script" bivy-gui-env "$BIVY_LAUNCHCTL"
  [ "$(cat "$STUB_DIR/PATH")" = "$SHIMS:$LOCAL_BIN:/usr/bin:/bin:/usr/sbin:/sbin" ]
}

@test "macOS: a config path with XML and shell characters survives" {
  need_plutil
  use_darwin
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/a&b <c> 'd'"
  bivy_init_paths
  bivy_ensure_dirs
  shell_write_env
  gui_apply
  plutil -lint "$PLIST"
  local script
  script=$(plutil -extract ProgramArguments.2 raw -o - "$PLIST")
  rm -f "$STUB_DIR/PATH"
  env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c "$script" bivy-gui-env "$BIVY_LAUNCHCTL"
  [ "$(cat "$STUB_DIR/PATH")" = "$SHIMS:$LOCAL_BIN:/usr/bin:/bin" ]
}

@test "Linux: environment.d puts the shims first, from the next login" {
  use_linux
  run gui_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"next login"* ]]
  [ "$(file_mode "$ENV_D")" = 644 ]
  grep -qxF "PATH=$SHIMS:\${HOME}/.local/bin:\${PATH}" "$ENV_D"
  run gui_apply
  [[ "$output" != *"next login"* ]]
  [ ! -e "$STUB_DIR/calls" ]
}

@test "Linux: a path that systemd could reinterpret is not written" {
  use_linux
  export MISE_DATA_DIR="$HOME/my \$dir"
  bivy_init_paths
  run gui_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot be written safely"* ]]
  [ ! -e "$ENV_D" ]
}
