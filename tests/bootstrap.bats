#!/usr/bin/env bats

load helper

setup() {
  sandbox_setup
  STUBS=$BATS_TEST_TMPDIR/stubs
  mkdir -p "$STUBS"
}

stub_uname() {
  printf '#!/bin/sh\necho %s\n' "$1" >"$STUBS/uname"
  chmod +x "$STUBS/uname"
}

# The bootstrap needs a published repository: this is a throwaway copy of the tree.
engine_repo() {
  ENGINE=$BATS_TEST_TMPDIR/engine
  mkdir -p "$ENGINE"
  (cd "$POVY_ROOT" && tar --exclude=.git -cf - .) | tar -xf - -C "$ENGINE"
  commit_all "$ENGINE"
  export POVY_REPO=$ENGINE
}

run_piped() {
  # shellcheck disable=SC2002
  run bash -c "cat '$POVY_ROOT/bootstrap' | PATH='$1' bash"
}

@test "native Windows is refused with a pointer to WSL2" {
  local name
  for name in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
    stub_uname "$name"
    run_piped "$STUBS:$PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Windows is not supported"* ]]
    [[ "$output" == *"wsl --install"* ]]
  done
  [ ! -e "$HOME/.local/share/povy" ]
}

@test "WSL1 is refused" {
  stub_uname Linux
  echo 'Linux version 4.4.0-19041-Microsoft' >"$BATS_TEST_TMPDIR/proc"
  export POVY_PROC_VERSION=$BATS_TEST_TMPDIR/proc
  run_piped "$STUBS:$PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WSL1 is not supported"* ]]
}

@test "an unknown system is refused" {
  stub_uname SunOS
  run_piped "$STUBS:$PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported system"* ]]
}

@test "the copy of the detection in bootstrap matches the engine" {
  extract() { sed -n '/^povy_detect_os() {$/,/^}$/p' "$1"; }
  [ -n "$(extract "$POVY_ROOT/bootstrap")" ]
  [ "$(extract "$POVY_ROOT/bootstrap")" = "$(extract "$POVY_ROOT/lib/common.sh")" ]
}

@test "piped, without a terminal: clones the engine and installs the command" {
  engine_repo
  run_piped "$PATH"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/povy" ]
  [ -f "$HOME/.local/share/povy/bin/povy" ]
  [[ "$output" == *"Next:"* ]]
  [ ! -e "$HOME/.config/povy/config.toml" ]
  run "$HOME/.local/bin/povy" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: povy"* ]]
}

@test "piped, with a terminal: answers come from it and the machine is configured" {
  engine_repo
  export POVY_TTY=$BATS_TEST_TMPDIR/tty
  # The same file serves the confirmation, then the three questions.
  printf 'Y\nuser@example.org\n\n' >"$POVY_TTY"
  run_piped "$PATH"
  [ "$status" -eq 0 ]
  grep -qxF 'name = "Y"' "$HOME/.config/povy/config.toml"
  grep -qxF 'email = "user@example.org"' "$HOME/.config/povy/config.toml"
  run "$HOME/.local/bin/povy" doctor
  [ "$status" -eq 0 ]
}

@test "a second run updates the clone" {
  engine_repo
  run_piped "$PATH"
  echo change >"$ENGINE/CHANGED"
  commit_all "$ENGINE"
  run_piped "$PATH"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.local/share/povy/CHANGED" ]
}

@test "a non-Git directory at the engine location is left alone" {
  engine_repo
  mkdir -p "$HOME/.local/share/povy"
  echo mine >"$HOME/.local/share/povy/file"
  run_piped "$PATH"
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.local/share/povy/file")" = mine ]
}

@test "an unrelated file at the command location is left alone" {
  engine_repo
  mkdir -p "$HOME/.local/bin"
  echo mine >"$HOME/.local/bin/povy"
  run_piped "$PATH"
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.local/bin/povy")" = mine ]
}

@test "mise is installed from mise.run when missing" {
  engine_repo
  ln -s "$(command -v git)" "$STUBS/git"
  cat >"$STUBS/curl" <<'SCRIPT'
#!/bin/sh
echo "$*" >"$HOME/curl.log"
cat <<'INSTALLER'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/mise"
chmod +x "$HOME/.local/bin/mise"
INSTALLER
SCRIPT
  chmod +x "$STUBS/curl"
  run_piped "$STUBS:/usr/bin:/bin"
  [ "$status" -eq 0 ]
  grep -qF 'https://mise.run' "$HOME/curl.log"
  [ -x "$HOME/.local/bin/mise" ]
}
