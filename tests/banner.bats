#!/usr/bin/env bats
# The banner: what it shows, the few problems it reports, and when it keeps quiet.

load helper

setup_file() {
  export REAL_HOME=$HOME
  sandbox_env "$BATS_FILE_TMPDIR/seed"
  export MISE_DATA_DIR="$BATS_SUITE_TMPDIR/mise-data"
  export MISE_CACHE_DIR="$BATS_SUITE_TMPDIR/mise-cache"
  make_profile_repo "$BATS_FILE_TMPDIR/profile"
  write_config "$BATS_FILE_TMPDIR/config.toml" "$BATS_FILE_TMPDIR/profile"
  povy init --config "$BATS_FILE_TMPDIR/config.toml"
  echo 'EXAMPLE_API_TOKEN=x' >>"$HOME/.config/povy/.env"
  povy apply
}

setup() {
  sandbox_setup
  cp -Rp "$BATS_FILE_TMPDIR/seed/." "$HOME/"
  SHIMS=$MISE_DATA_DIR/shims
  cd "$HOME"
}

# The compact banner with ASCII marks, whatever the locale and the width of the
# terminal that runs the tests. The caller sets PATH.
ascii_banner() {
  LC_ALL=C LANG=C COLUMNS=0 "$POVY_ROOT/bin/povy" banner "$@"
}

# The same with the PATH that the startup files give a terminal.
banner() {
  PATH="$SHIMS:$PATH" ascii_banner "$@"
}

@test "a healthy machine: who and where, its load, its tools, tools ready" {
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *povy*"$(id -un)@"*"profile profile"* ]] || false
  [[ "${lines[1]}" == *"cpu "*"%"* ]] || false
  [[ "${lines[1]}" == *"ram "*"%"*G* ]] || false
  [[ "${lines[1]}" == *"disk "*"%"*G* ]] || false
  [[ "${lines[2]}" == *"jq 1.7.1"* ]] || false
  [[ "$output" != *"yq "* ]] || false
  [ "${lines[${#lines[@]} - 1]}" = "   ok tools ready" ]
  [[ "$output" != *$'\033'* ]] || false
}

@test "versions are shortened, the first of a list comes first" {
  load_libs
  [ "$(short_version temurin-21.0.13+100000002.0.LTS)" = 21.0.13 ]
  [ "$(short_version liberica-javafx-8u492+9)" = 8u492 ]
  [ "$(short_version 22.23.5)" = 22.23.5 ]
  [ "$(short_version 1.2.3-rc1)" = 1.2.3-rc1 ]
}

@test "each problem gets a line, and doctor is suggested" {
  printf '[tools]\njq = "1.5"\n' >"$HOME/.config/mise/conf.d/zz-test.toml"
  rm "$HOME/.local/state/povy/applied"
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n''   x not installed: jq@1.5; run: povy apply'$'\n'* ]] || false
  [[ "$output" == *$'\n''   ! povy apply has not run yet'$'\n'* ]] || false
  [ "${lines[${#lines[@]} - 1]}" = "   povy doctor tells more" ]
  [[ "$output" != *"tools ready"* ]] || false
}

@test "a tool that is declared but not installed is reported" {
  printf '[tools]\njq = "1.5"\n' >"$HOME/.config/mise/conf.d/zz-test.toml"
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed: jq@1.5; run: povy apply"* ]] || false
}

@test "before the first apply, the banner says so" {
  rm "$HOME/.local/state/povy/applied"
  run banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"povy apply has not run yet"* ]] || false
}

@test "a machine without mise is reported, and the banner still shows" {
  local tool bin=$BATS_TEST_TMPDIR/bin
  mkdir "$bin"
  for tool in bash env sh uname grep tail head stat dirname readlink awk tr cat sed date df id tput \
    getconf sort locale; do
    ln -s "$(command -v "$tool")" "$bin/$tool" 2>/dev/null || true
  done
  PATH=$bin run ascii_banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *povy*"$(id -un)@"* ]] || false
  [[ "$output" == *"x mise is not installed; run the povy bootstrap"* ]] || false
  [[ "$output" == *"povy doctor tells more"* ]] || false
}

@test "a disk almost full is reported" {
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  cat >"$BATS_TEST_TMPDIR/stubs/df" <<'SH'
#!/bin/sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo '/dev/disk1 1000000000 950000000 50000000 95% /'
SH
  chmod +x "$BATS_TEST_TMPDIR/stubs/df"
  PATH="$BATS_TEST_TMPDIR/stubs:$SHIMS:$PATH" run ascii_banner
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"disk 95%"* ]] || false
  [[ "$output" == *"! the disk holding $HOME is almost full"* ]] || false
}

@test "the thorough checks are left to doctor" {
  # Things doctor reports, and the banner does not look at.
  chmod 644 "$HOME/.config/povy/.env"
  sed -i.bak 's/^EXAMPLE_API_TOKEN=x$/EXAMPLE_API_TOKEN=/' "$HOME/.config/povy/.env"
  printf '[user]\n\temail = old@example.org\n' >>"$HOME/.gitconfig"
  rm "$HOME/.config/povy-example/example.conf"
  run ascii_banner
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "   ok tools ready" ]
}

@test "--auto keeps quiet in IDEs and agents, and POVY_BANNER decides" {
  local quiet
  for quiet in TERM_PROGRAM=vscode TERM_PROGRAM=zed TERMINAL_EMULATOR=JetBrains-JediTerm \
    CLAUDECODE=1 INSIDE_EMACS=29.1 TERM=dumb POVY_BANNER=0; do
    run env "$quiet" PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner --auto
    [ "$status" -eq 0 ]
    [ -z "$output" ] || {
      echo "not quiet with $quiet"
      return 1
    }
  done
  run env TERM_PROGRAM=vscode POVY_BANNER=1 PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner --auto
  [[ "$output" == *"tools ready"* ]] || false
  TERM=xterm-256color run banner --auto
  [[ "$output" == *"tools ready"* ]] || false
}

@test "the startup files show nothing in a shell that is not interactive or not in a terminal" {
  local interactive=$HOME/.config/povy/interactive.sh
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
  echo "$output"
  [ "$(printf '%s\n' "$output" | grep -c 'tools ready')" -eq 1 ]
}

@test "banner = false in config.toml keeps the startup files quiet" {
  cp "$BATS_FILE_TMPDIR/config.toml" "$BATS_TEST_TMPDIR/c.toml"
  printf 'banner = false\n' >>"$BATS_TEST_TMPDIR/c.toml"
  povy init --config "$BATS_TEST_TMPDIR/c.toml"
  povy apply
  ! grep -q 'banner --auto' "$HOME/.config/povy/interactive.sh" || false
  run banner
  echo "$output"
  [[ "$output" == *"tools ready"* ]] || false
}

@test "banner must be true or false" {
  write_config "$BATS_TEST_TMPDIR/c.toml"
  printf 'banner = "no"\n' >>"$BATS_TEST_TMPDIR/c.toml"
  run povy init --config "$BATS_TEST_TMPDIR/c.toml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"banner must be true or false"* ]] || false
}

# A UTF-8 locale this system has: en_US on macOS, C on most Linux.
utf8_locale() {
  locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -n 1
}

wide_banner() {
  local loc
  loc=$(utf8_locale)
  [ -n "$loc" ] || skip "no UTF-8 locale"
  run env COLUMNS=100 LANG="$loc" LC_ALL="$loc" PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner "$@"
  echo "$output"
}

# Every framed row has the width of the first line.
same_width() {
  local loc=$1 width line
  width=$(LC_ALL=$loc bash -c 'printf "%s" "${#1}"' _ "${lines[0]}")
  for line in "${lines[@]}"; do
    case "$line" in
      "  │"*"│")
        [ "$(LC_ALL=$loc bash -c 'printf "%s" "${#1}"' _ "$line")" -eq "$width" ] || {
          echo "not $width wide: $line"
          return 1
        }
        ;;
    esac
  done
}

@test "a wide UTF-8 terminal gets the framed banner, every framed row the same width" {
  wide_banner
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "  ╭"*"╮" ]] || false
  [[ "$output" == *"██████╗  ██████╗ ██╗   ██╗██╗   ██╗"* ]] || false
  [[ "$output" == *"╭─ system"* && "$output" == *"├─ tools"* ]] || false
  [[ "$output" == *"│  jq  1.7.1"* ]] || false
  [[ "${lines[${#lines[@]} - 1]}" == "  ╰─ ✓ tools ready  povy doctor checks the rest" ]] || false
  [[ "$output" != *"health"* ]] || false
  same_width "$(utf8_locale)"
}

@test "a long host name stays inside the frame" {
  local loc host
  loc=$(utf8_locale)
  [ -n "$loc" ] || skip "no UTF-8 locale"
  host=$(printf 'h%.0s' $(seq 1 90))
  run env HOSTNAME="$host" COLUMNS=100 LANG="$loc" LC_ALL="$loc" PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner
  echo "$output"
  [[ "$output" == *"hhh…"* ]] || false
  same_width "$loc"
}

@test "in the framed banner, a problem opens the health section" {
  rm "$HOME/.local/state/povy/applied"
  wide_banner
  [[ "$output" == *"├─ health"* ]] || false
  [[ "$output" == *"│  ! povy apply has not run yet"* ]] || false
  [ "${lines[${#lines[@]} - 1]}" = "  ╰─ povy doctor tells more" ]
}

@test "a narrow terminal or a locale without UTF-8 gets the compact banner" {
  local loc
  loc=$(utf8_locale)
  [ -n "$loc" ] || skip "no UTF-8 locale"
  run env COLUMNS=70 LANG="$loc" LC_ALL="$loc" PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner
  [[ "$output" != *"╭"* ]] || false
  [[ "$output" == *"✓ tools ready"* ]] || false
  run env COLUMNS=100 LANG=C LC_ALL=C PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner
  [[ "$output" != *"╭"* ]] || false
  [[ "$output" == *"ok tools ready"* ]] || false
}

@test "CLICOLOR_FORCE colours the banner outside a terminal, and NO_COLOR wins" {
  run env CLICOLOR_FORCE=1 PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner
  [[ "$output" == *$'\033['* ]] || false
  run env CLICOLOR_FORCE=1 NO_COLOR=1 PATH="$SHIMS:$PATH" "$POVY_ROOT/bin/povy" banner
  [[ "$output" != *$'\033['* ]] || false
}
