#!/usr/bin/env bats
# The banner: what it shows, the problems it reports, and when it keeps quiet.

load helper

setup_file() {
  export REAL_HOME=$HOME
  sandbox_env "$BATS_FILE_TMPDIR/seed"
  export MISE_DATA_DIR="$BATS_SUITE_TMPDIR/mise-data"
  export MISE_CACHE_DIR="$BATS_SUITE_TMPDIR/mise-cache"
  make_profile_repo "$BATS_FILE_TMPDIR/profile"
  write_config "$BATS_FILE_TMPDIR/config.toml" "$BATS_FILE_TMPDIR/profile"
  bivy init --config "$BATS_FILE_TMPDIR/config.toml"
  echo 'EXAMPLE_API_TOKEN=x' >>"$HOME/.config/bivy/.env"
  bivy apply
}

# The dates matter: the banner compares config.toml and .env with the last apply.
setup() {
  sandbox_setup
  cp -Rp "$BATS_FILE_TMPDIR/seed/." "$HOME/"
  SHIMS=$MISE_DATA_DIR/shims
  printf '%s\n' "$SHIMS:/usr/bin:/bin" >"${BIVY_LAUNCHCTL%/*}/PATH"
  cd "$HOME"
}

# Runs the banner with the PATH that the startup files give a terminal.
banner() {
  PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner "$@"
}

@test "a healthy machine: who and where, its load, its tools, all good" {
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *bivy*"$(id -un)@"*"profile profile"* ]]
  [[ "${lines[1]}" == *"cpu "*"%"* ]]
  [[ "${lines[1]}" == *"ram "*"%"*G* ]]
  [[ "${lines[1]}" == *"disk "*"%"*G* ]]
  [[ "${lines[2]}" == *"jq 1.7.1"* ]]
  [[ "$output" != *"yq "* ]]
  [[ "$output" == *"all good"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "versions are shortened, the first of a list comes first" {
  load_libs
  [ "$(short_version temurin-21.0.13+100000002.0.LTS)" = 21.0.13 ]
  [ "$(short_version liberica-javafx-8u492+9)" = 8u492 ]
  [ "$(short_version 22.23.5)" = 22.23.5 ]
  [ "$(short_version 1.2.3-rc1)" = 1.2.3-rc1 ]
}

@test "each problem gets a line, and doctor is suggested" {
  sed -i.bak 's/^EXAMPLE_API_TOKEN=x$/EXAMPLE_API_TOKEN=/' "$HOME/.config/bivy/.env"
  chmod 644 "$HOME/.config/bivy/.env"
  touch -t 203001010000 "$HOME/.config/bivy/config.toml"
  rm "$HOME/.config/bivy-example/example.conf"
  printf '[user]\n\temail = old@example.org\n' >>"$HOME/.gitconfig"
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty secrets in ~/.config/bivy/.env: EXAMPLE_API_TOKEN"* ]]
  [[ "$output" == *"~/.config/bivy/.env has mode 644, expected 600"* ]]
  [[ "$output" == *"config.toml changed since the last bivy apply"* ]]
  [[ "$output" == *".env changed since the last bivy apply"* ]]
  [[ "$output" == *"~/.config/bivy-example/example.conf is missing"* ]]
  [[ "$output" == *"overrides it in: $HOME/.gitconfig"* ]]
  [[ "$output" == *"bivy doctor tells more"* ]]
  [[ "$output" != *"all good"* ]]
}

@test "a shell without the shims on its PATH is reported" {
  run "$BIVY_ROOT/bin/bivy" banner
  echo "$output"
  [[ "$output" == *"shims are not on the PATH of this shell"* ]]
}

@test "a command that an earlier directory of PATH hides is reported" {
  mkdir -p "$HOME/fakebin"
  printf '#!/bin/sh\necho fake\n' >"$HOME/fakebin/jq"
  chmod +x "$HOME/fakebin/jq"
  run env PATH="$HOME/fakebin:$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner
  echo "$output"
  [[ "$output" == *"~/fakebin hides jq before the mise shims"* ]]
}

@test "a tool that is declared but not installed is reported" {
  printf '[tools]\njq = "1.6"\n' >"$HOME/.config/mise/conf.d/zz-test.toml"
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed: jq@1.6; run: bivy apply"* ]]
}

@test "before the first apply, the banner says so" {
  rm "$HOME/.local/state/bivy/applied"
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bivy apply has not run yet"* ]]
}

@test "macOS: graphical apps without the shims are reported" {
  [ "$(uname -s)" = Darwin ] || skip "macOS only"
  rm "${BIVY_LAUNCHCTL%/*}/PATH"
  run banner
  echo "$output"
  [[ "$output" == *"graphical apps do not see the shims"* ]]
}

@test "--auto keeps quiet in IDEs and agents, and BIVY_BANNER decides" {
  local quiet
  for quiet in TERM_PROGRAM=vscode TERM_PROGRAM=zed TERMINAL_EMULATOR=JetBrains-JediTerm \
    CLAUDECODE=1 INSIDE_EMACS=29.1 TERM=dumb BIVY_BANNER=0; do
    run env "$quiet" PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner --auto
    [ "$status" -eq 0 ]
    [ -z "$output" ] || {
      echo "not quiet with $quiet"
      return 1
    }
  done
  run env TERM_PROGRAM=vscode BIVY_BANNER=1 PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner --auto
  [[ "$output" == *"all good"* ]]
  TERM=xterm-256color run banner --auto
  [[ "$output" == *"all good"* ]]
}

@test "the startup files show nothing in a shell that is not interactive or not in a terminal" {
  local interactive=$HOME/.config/bivy/interactive.sh
  run bash -c ". '$interactive'"
  [ -z "$output" ]
  run bash -c "bash -i -c '. \"$interactive\"' 2>/dev/null | cat"
  [ -z "$output" ]
}

@test "in a terminal, the banner shows once, even when .bash_profile sources .bashrc" {
  command -v script >/dev/null || skip "script is not installed"
  local login
  login=$(find "$HOME" -maxdepth 1 \( -name .bash_profile -o -name .profile \) | head -n 1)
  printf '. "$HOME/.bashrc"\n' >>"$login"
  # script gives the shell a terminal; its options differ between BSD and util-linux.
  if [ "$(uname -s)" = Darwin ]; then
    run script -q /dev/null env TERM=xterm-256color PATH="/usr/bin:/bin:$PATH" bash -l -i -c true </dev/null
  else
    run script -qec "env TERM=xterm-256color PATH='/usr/bin:/bin:$PATH' bash -l -i -c true" /dev/null </dev/null
  fi
  [ "$(printf '%s\n' "$output" | grep -c 'all good')" -eq 1 ]
}

@test "banner = false in config.toml keeps the startup files quiet" {
  cp "$BATS_FILE_TMPDIR/config.toml" "$BATS_TEST_TMPDIR/c.toml"
  printf 'banner = false\n' >>"$BATS_TEST_TMPDIR/c.toml"
  bivy init --config "$BATS_TEST_TMPDIR/c.toml"
  bivy apply
  ! grep -q 'banner --auto' "$HOME/.config/bivy/interactive.sh"
  grep -qF 'banner = false' "$HOME/.config/bivy/interactive.sh"
  run banner
  echo "$output"
  [[ "$output" == *"all good"* ]]
}

@test "banner must be true or false" {
  write_config "$BATS_TEST_TMPDIR/c.toml"
  printf 'banner = "no"\n' >>"$BATS_TEST_TMPDIR/c.toml"
  run bivy init --config "$BATS_TEST_TMPDIR/c.toml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"banner must be true or false"* ]]
}

# A UTF-8 locale this system has: en_US on macOS, C on most Linux.
utf8_locale() {
  locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -n 1
}

wide_banner() {
  local loc
  loc=$(utf8_locale)
  [ -n "$loc" ] || skip "no UTF-8 locale"
  run env COLUMNS=100 LANG="$loc" LC_ALL="$loc" PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner "$@"
  echo "$output"
}

@test "a wide UTF-8 terminal gets the framed banner, every framed row the same width" {
  wide_banner
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "  ╭"*"╮" ]]
  [[ "$output" == *"██████╗ ██╗██╗   ██╗██╗   ██╗"* ]]
  [[ "$output" == *"╭─ system"* && "$output" == *"├─ tools"* ]]
  [[ "${lines[${#lines[@]} - 1]}" == "  ╰─ ✓ all good"* ]]
  [[ "$output" != *"health"* ]]
  local loc width line
  loc=$(utf8_locale)
  width=$(LC_ALL=$loc bash -c 'printf "%s" "${#1}"' _ "${lines[0]}")
  for line in "${lines[@]}"; do
    case "$line" in
      "  │"*"│") [ "$(LC_ALL=$loc bash -c 'printf "%s" "${#1}"' _ "$line")" -eq "$width" ] ;;
    esac
  done
}

@test "a long host name stays inside the frame" {
  local loc width line host
  loc=$(utf8_locale)
  [ -n "$loc" ] || skip "no UTF-8 locale"
  host=$(printf 'h%.0s' $(seq 1 90))
  run env HOSTNAME="$host" COLUMNS=100 LANG="$loc" LC_ALL="$loc" PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner
  echo "$output"
  [[ "$output" == *"hhh…"* ]]
  width=$(LC_ALL=$loc bash -c 'printf "%s" "${#1}"' _ "${lines[0]}")
  for line in "${lines[@]}"; do
    case "$line" in
      "  │"*"│") [ "$(LC_ALL=$loc bash -c 'printf "%s" "${#1}"' _ "$line")" -eq "$width" ] ;;
    esac
  done
}

@test "in the framed banner, a problem opens the health section" {
  rm "$HOME/.config/bivy-example/example.conf"
  wide_banner
  [[ "$output" == *"├─ health"* ]]
  [[ "$output" == *"│  ✗ ~/.config/bivy-example/example.conf is missing; run: bivy apply"* ]]
  [[ "${lines[${#lines[@]} - 1]}" == "  ╰─ bivy doctor tells more" ]]
}

@test "a narrow terminal or a locale without UTF-8 gets the compact banner" {
  local loc
  loc=$(utf8_locale)
  [ -n "$loc" ] || skip "no UTF-8 locale"
  run env COLUMNS=70 LANG="$loc" LC_ALL="$loc" PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner
  [[ "$output" != *"╭"* ]]
  [[ "$output" == *"all good"* ]]
  run env COLUMNS=100 LANG=C LC_ALL=C PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner
  [[ "$output" != *"╭"* ]]
  [[ "$output" == *"all good"* ]]
}

@test "CLICOLOR_FORCE colours the banner outside a terminal, and NO_COLOR wins" {
  run env CLICOLOR_FORCE=1 PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner
  [[ "$output" == *$'\033['* ]]
  run env CLICOLOR_FORCE=1 NO_COLOR=1 PATH="$SHIMS:$PATH" "$BIVY_ROOT/bin/bivy" banner
  [[ "$output" != *$'\033['* ]]
}
