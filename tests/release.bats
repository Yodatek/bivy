#!/usr/bin/env bats
# scripts/release and povy version, on a throwaway repository and its origin.

load helper

setup() {
  sandbox_setup
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
  REPO=$BATS_TEST_TMPDIR/repo
  git init --quiet --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git clone --quiet "$BATS_TEST_TMPDIR/origin.git" "$REPO" 2>/dev/null
  mkdir -p "$REPO/scripts"
  cp "$POVY_ROOT/scripts/release" "$REPO/scripts/"
  cat >"$REPO/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

## [1.2.0] - 2026-01-02

### Added

- Something new.

## [1.1.0] - 2026-01-01

- Older.

[Unreleased]: https://example.org/compare
[1.2.0]: https://example.org/1.2.0
MD
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m init
  git -C "$REPO" push --quiet origin main 2>/dev/null
  RELEASE=$REPO/scripts/release
}

commit() {
  echo "$1" >"$REPO/$1"
  git -C "$REPO" add "$1"
  git -C "$REPO" commit --quiet -m "$1"
}

@test "notes are the version's section, without the blank lines around it" {
  run "$RELEASE" notes v1.2.0
  [ "$status" -eq 0 ]
  [ "$output" = $'### Added\n\n- Something new.' ]
  run "$RELEASE" notes v1.1.0
  [ "$output" = "- Older." ]
  run "$RELEASE" notes v9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"no section for 9.9.9"* ]]
  run "$RELEASE" notes 1.2.0
  [ "$status" -ne 0 ]
}

@test "tag creates an annotated tag holding the notes, once" {
  run "$RELEASE" tag v1.2.0
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" cat-file -t refs/tags/v1.2.0)" = tag ]
  [ "$(git -C "$REPO" tag -l --format='%(contents)' v1.2.0)" = $'povy 1.2.0\n\n### Added\n\n- Something new.' ]
  run "$RELEASE" tag v1.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "tag refuses a dirty tree, another branch and a main that is not pushed" {
  touch "$REPO/stray"
  run "$RELEASE" tag v1.2.0
  [[ "$output" == *"not clean"* ]]
  rm "$REPO/stray"
  git -C "$REPO" switch --quiet -c side
  run "$RELEASE" tag v1.2.0
  [[ "$output" == *"tagged on main"* ]]
  git -C "$REPO" switch --quiet main
  commit unpushed
  run "$RELEASE" tag v1.2.0
  [[ "$output" == *"differs from origin/main"* ]]
  ! git -C "$REPO" rev-parse --quiet --verify refs/tags/v1.2.0
}

@test "check accepts an annotated tag on main, and refuses a lightweight one or one off main" {
  git -C "$REPO" tag --annotate -m "povy 1.2.0" v1.2.0
  run "$RELEASE" check v1.2.0
  [ "$status" -eq 0 ]
  git -C "$REPO" tag v1.1.0
  run "$RELEASE" check v1.1.0
  [[ "$output" == *"not an annotated tag"* ]]
  git -C "$REPO" tag -d v1.1.0 >/dev/null
  git -C "$REPO" switch --quiet -c side
  commit side
  git -C "$REPO" tag --annotate -m "povy 1.1.0" v1.1.0
  run "$RELEASE" check v1.1.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on main"* ]]
}

@test "povy version follows the annotated release tags of its clone" {
  load_libs
  version() { (POVY_ROOT=$REPO && povy_version); }
  [ "$(version)" = "$(git -C "$REPO" rev-parse --short HEAD)" ]
  git -C "$REPO" tag --annotate -m "povy 1.2.0" v1.2.0
  [ "$(version)" = 1.2.0 ]
  commit later
  git -C "$REPO" tag v1.3.0
  [ "$(version)" = "1.2.0-1-g$(git -C "$REPO" rev-parse --short HEAD)" ]
  touch "$REPO/CHANGELOG.md" && echo >>"$REPO/CHANGELOG.md"
  [[ "$(version)" == *-dirty ]]
  run povy --version
  [ "$status" -eq 0 ]
  [[ "$output" == "povy "?* ]]
}
