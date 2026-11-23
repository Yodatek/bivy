#!/usr/bin/env bats
# Contexts: a Git identity, a profile, or both, below a directory, which mise and
# Git apply there, for IDEs and agents too.

load helper

setup() {
  sandbox_setup
  CONFIG=$BATS_TEST_TMPDIR/config.toml
  STATE=$HOME/.local/state/povy
}

# The default identity, no default profile, then the lines given.
write_contexts() {
  write_config "$CONFIG"
  printf '%s\n' "$@" >>"$CONFIG"
}

# A context table: id, dir, then key = "value" pairs.
context() {
  local id=$1 dir=$2 pair
  shift 2
  printf '\n[contexts.%s]\ndir = "%s"\n' "$id" "$dir"
  for pair in "$@"; do
    printf '%s = "%s"\n' "${pair%%=*}" "${pair#*=}"
  done
}

# What an IDE or an agent started in a directory sees: no mise on PATH, nothing but
# the startup files of a login shell.
ide_run() {
  local dir=$1
  shift
  mkdir -p "$dir"
  (cd "$dir" && env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin \
    MISE_DATA_DIR="$MISE_DATA_DIR" MISE_CACHE_DIR="$MISE_CACHE_DIR" bash -lc "$*" 2>/dev/null)
}

# The value of an environment variable as a tool started through a mise shim sees it.
ide_env() {
  ide_run "$1" "yq -n 'env($2)' || echo none"
}

apply_ok() {
  run povy apply
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a context's team.toml applies below its directory, for an IDE too" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" '[env]
CTX = "a"' ""
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")"
  povy init --config "$CONFIG"
  apply_ok
  grep -qxF "include = [\"$STATE/contexts/a/profile/team.toml\"]" "$HOME/work/a/.config/mise/conf.d/povy.toml"
  [ "$(ide_env "$HOME/work/a/project" CTX)" = a ]
  [ "$(ide_env "$HOME/work" CTX)" = none ]
  [ "$(ide_env "$HOME" CTX)" = none ]
}

@test "in nested contexts the deepest wins, and the parent still applies" {
  make_mise_profile "$BATS_TEST_TMPDIR/org" '[env]
ORG = "org"
CTX = "org"' ""
  make_mise_profile "$BATS_TEST_TMPDIR/product" '[env]
CTX = "product"' ""
  write_contexts "$(context org '~/work/org/' profile="$BATS_TEST_TMPDIR/org")" \
    "$(context product '~/work/org/product/' profile="$BATS_TEST_TMPDIR/product")"
  povy init --config "$CONFIG"
  apply_ok
  [ "$(ide_env "$HOME/work/org/product/app" CTX)" = product ]
  [ "$(ide_env "$HOME/work/org/product/app" ORG)" = org ]
  [ "$(ide_env "$HOME/work/org/other" CTX)" = org ]
}

@test "a context sets the Git identity below its directory, the deepest winning" {
  local repo
  write_contexts "$(context org '~/work/org/' email=org@example.org)" \
    "$(context product '~/work/org/product/' email=product@example.org name=Prod)"
  povy init --config "$CONFIG"
  apply_ok
  for repo in work/org/product/r work/org/r r; do
    mkdir -p "$HOME/$repo"
    git -C "$HOME/$repo" init --quiet
  done
  [ "$(git -C "$HOME/work/org/product/r" config user.email)" = product@example.org ]
  [ "$(git -C "$HOME/work/org/product/r" config user.name)" = Prod ]
  [ "$(git -C "$HOME/work/org/r" config user.email)" = org@example.org ]
  [ "$(git -C "$HOME/work/org/r" config user.name)" = "Test User" ]
  [ "$(git -C "$HOME/r" config user.email)" = test@example.org ]
  # An identity only: no clone and no mise config.
  [ ! -e "$HOME/work/org/.config/mise/conf.d/povy.toml" ]
  [ ! -e "$STATE/contexts/org" ]
}

@test "a context reads its secrets in its own .env, then in the shared one" {
  local p=$BATS_TEST_TMPDIR/s
  make_mise_profile "$p" "" "$(out_file_project TOKEN)" 'files/t={{ secret(name="TOKEN") }}'
  write_contexts "$(context s '~/work/s/' profile="$p")"
  povy init --config "$CONFIG"
  run povy apply
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *TOKEN*"in ~/.config/povy/s.env"*"secrets above are empty"* ]] || false
  grep -qx 'TOKEN=' "$HOME/.config/povy/s.env"
  [ "$(file_mode "$HOME/.config/povy/s.env")" = 600 ]
  [ ! -e "$HOME/.out" ]

  printf 'TOKEN=shared\n' >>"$HOME/.config/povy/.env"
  apply_ok
  [ "$(cat "$HOME/.out/t")" = shared ]
  printf 'TOKEN=own\n' >"$HOME/.config/povy/s.env"
  apply_ok
  [ "$(cat "$HOME/.out/t")" = own ]
}

@test "two profiles that write the same file stop apply before anything changes" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" '[env]
CTX = "a"' "$(out_file_project)" 'files/t=a'
  make_mise_profile "$BATS_TEST_TMPDIR/b" "" "$(out_file_project)" 'files/t=b'
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")" \
    "$(context b '~/work/b/' profile="$BATS_TEST_TMPDIR/b")"
  povy init --config "$CONFIG"
  run povy apply
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.out/t: written by context a and by context b"* ]] || false
  [ ! -e "$HOME/.out" ]
  [ ! -e "$HOME/work/a/.config/mise/conf.d/povy.toml" ]

  run povy doctor
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"two profiles write ~/.out/t"* ]] || false
}

@test "two blocks of different ids in one rc file do not conflict" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" "" '[bootstrap.files."~/.bashrc"]
id = "a"
block = "export FROM_A=1"'
  make_mise_profile "$BATS_TEST_TMPDIR/b" "" '[bootstrap.files."~/.bashrc"]
id = "b"
block = "export FROM_B=1"'
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")" \
    "$(context b '~/work/b/' profile="$BATS_TEST_TMPDIR/b")"
  povy init --config "$CONFIG"
  apply_ok
  grep -qxF 'export FROM_A=1' "$HOME/.bashrc"
  grep -qxF 'export FROM_B=1' "$HOME/.bashrc"

  printf '[bootstrap.files."~/.bashrc"]\nid = "a"\nblock = "export FROM_B=2"\n' >"$BATS_TEST_TMPDIR/b/mise.toml"
  commit_all "$BATS_TEST_TMPDIR/b"
  run povy apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.bashrc: written by context a and by context b"* ]] || false
}

@test "every profile's commands are on PATH, and the first in config.toml wins a name" {
  local bin='[_.povy]
bin = "bin"'
  make_mise_profile "$BATS_TEST_TMPDIR/a" "" "$bin" 'bin/hello=#!/bin/sh
echo from-a' 'bin/only-a=#!/bin/sh
echo only-a'
  make_mise_profile "$BATS_TEST_TMPDIR/b" "" "$bin" 'bin/hello=#!/bin/sh
echo from-b' 'bin/only-b=#!/bin/sh
echo only-b'
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")" \
    "$(context b '~/work/b/' profile="$BATS_TEST_TMPDIR/b")"
  povy init --config "$CONFIG"
  apply_ok
  [[ "$output" == *"hello: in context a and in context b; the first wins"* ]] || false
  [ "$(ide_run "$HOME" hello)" = from-a ]
  [ "$(ide_run "$HOME" only-b)" = only-b ]

  run povy doctor
  echo "$output"
  [[ "$output" == *"[warn] command hello: in context a and in context b"* ]] || false
}

@test "a context that goes, or moves, takes its mise config and its clone along" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" '[env]
CTX = "a"' ""
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")"
  povy init --config "$CONFIG"
  apply_ok
  printf 'KEEP=1\n' >"$HOME/.config/povy/a.env"
  mkdir -p "$HOME/work/a/.config/mise/conf.d"
  touch "$HOME/work/a/.config/mise/conf.d/mine.toml"

  write_contexts "$(context a '~/work/moved/' profile="$BATS_TEST_TMPDIR/a")"
  povy init --config "$CONFIG"
  apply_ok
  [ ! -e "$HOME/work/a/.config/mise/conf.d/povy.toml" ]
  [ -e "$HOME/work/a/.config/mise/conf.d/mine.toml" ]
  [ -e "$HOME/work/moved/.config/mise/conf.d/povy.toml" ]
  [ "$(ide_env "$HOME/work/moved" CTX)" = a ]

  write_contexts
  povy init --config "$CONFIG"
  apply_ok
  [ ! -e "$HOME/work/moved/.config" ]
  [ ! -e "$STATE/contexts/a" ]
  grep -qx 'KEEP=1' "$HOME/.config/povy/a.env"
}

@test "a mise config that povy did not write stays when its context goes" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" '[env]
CTX = "a"' ""
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")"
  povy init --config "$CONFIG"
  apply_ok
  printf '# mine now\n[env]\nCTX = "mine"\n' >"$HOME/work/a/.config/mise/conf.d/povy.toml"
  write_contexts
  povy init --config "$CONFIG"
  apply_ok
  grep -qxF '# mine now' "$HOME/work/a/.config/mise/conf.d/povy.toml"
}

@test "a second apply with contexts changes nothing" {
  local before
  make_mise_profile "$BATS_TEST_TMPDIR/a" '[env]
CTX = "a"' ""
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a" email=a@example.org)"
  povy init --config "$CONFIG"
  apply_ok
  before=$(home_fingerprint)
  apply_ok
  [[ "$output" == *"0 written"* ]] || false
  [ "$(home_fingerprint)" = "$before" ]
}

@test "doctor checks each context, and fails when the shims cannot run in one" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" '[env]
CTX = "a"' ""
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")"
  povy init --config "$CONFIG"
  apply_ok
  run povy doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]   context a: the mise shims run in ~/work/a"* ]] || false

  mise trust --quiet --untrust "$HOME/work/a/.config/mise/conf.d/povy.toml"
  run povy doctor
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"[FAIL] context a: the mise shims do not run in ~/work/a"* ]] || false
}

@test "status lists the contexts of a directory, the deepest first, then the default" {
  make_mise_profile "$BATS_TEST_TMPDIR/product" '[env]
CTX = "product"' ""
  write_contexts "$(context org '~/work/org/' email=org@example.org)" \
    "$(context product '~/work/org/product/' profile="$BATS_TEST_TMPDIR/product" profile_ref=main)"
  povy init --config "$CONFIG"
  mkdir -p "$HOME/work/org/product/app"
  run povy status "$HOME/work/org/product/app"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "~/work/org/product/app, the first that sets something wins:" ]
  [[ "${lines[1]}" == *"product"*"~/work/org/product/: profile product at main" ]] || false
  [[ "${lines[2]}" == *"org"*"~/work/org/: Git identity org@example.org" ]] || false
  [[ "${lines[3]}" == *"(default)"*"every directory: Git identity test@example.org" ]] || false

  run povy status "$HOME"
  [ "${#lines[@]}" -eq 2 ]
}

@test "the banner names the context of the current directory" {
  write_contexts "$(context org '~/work/org/' email=org@example.org)"
  povy init --config "$CONFIG"
  apply_ok
  mkdir -p "$HOME/work/org/app"
  run bash -c 'cd "$1" && LC_ALL=C LANG=C COLUMNS=0 "$2/bin/povy" banner' _ "$HOME/work/org/app" "$POVY_ROOT"
  echo "$output"
  [[ "$output" == *"context org"* ]] || false
}

@test "config.toml refuses contexts it cannot apply" {
  local body
  for body in '[contexts.Bad]
dir = "~/w/"
email = "a@example.org"' '[contexts.a]
email = "a@example.org"' '[contexts.a]
dir = "w/"
email = "a@example.org"' '[contexts.a]
dir = "~/"
email = "a@example.org"' '[contexts.a]
dir = "~/w/"' '[contexts.a]
dir = "~/w/"
name = "A"' '[contexts.a]
dir = "~/w/"
email = "a@example.org"
profile_ref = "main"' '[contexts.a]
dir = "~/w/"
email = "a@example.org"
colour = "red"' '[contexts.a]
dir = "~/w/"
email = "a@example.org"
[contexts.b]
dir = "~/w"
email = "b@example.org"' 'contexts = 1'; do
    write_contexts "$body"
    run povy init --config "$CONFIG"
    [ "$status" -ne 0 ] || {
      echo "accepted: $body"
      return 1
    }
    [[ "$output" == *"context"* ]] || {
      echo "unclear: $output"
      return 1
    }
  done
}

@test "doctor reports, and does not stop on, a [bootstrap.files] table it cannot read" {
  make_mise_profile "$BATS_TEST_TMPDIR/a" "" '[bootstrap.files]
"~/x" = "not a table"'
  write_contexts "$(context a '~/work/a/' profile="$BATS_TEST_TMPDIR/a")"
  povy init --config "$CONFIG"
  run povy doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"povy doctor found problems."* ]] || false
}
