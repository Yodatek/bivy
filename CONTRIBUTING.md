# Contributing to bivy

Bug reports, fixes and ideas are welcome. For anything larger than a fix, open an issue
first, so that we agree on the change before you write it.

By taking part, you agree to follow the [code of conduct](CODE_OF_CONDUCT.md). Report
security issues privately, as [SECURITY.md](SECURITY.md) explains, never in a public issue.

## Ground rules

- The engine stays generic. Nothing in it names a person, a company, an internal host
  or an account. What a team needs goes in its profile; the engine only gains a key when
  several profiles would use it.
- Code, comments, messages and documentation are in English.
- The code runs on bash 3.2, the version macOS ships, and on the GNU and BSD tools of
  Linux and macOS.
- bivy keeps the real `HOME` and changes the user's files only inside its marked blocks
  or after a backup.

## Set up

Tests, lint and the secret scan run with [mise](https://mise.jdx.dev):

```bash
mise trust
```

```bash
mise run test
```

```bash
mise run lint
```

Each test gets a temporary `HOME` and stubs for `launchctl`, so the suite never touches
your own files or graphical session. Enable the hook that scans the history for secrets
before each push:

```bash
git config core.hooksPath .githooks
```

`mise run banner-image` renders `docs/banner.png` again from your own banner, with the
user, host and profile replaced.

## Changes

- A change of behavior comes with a [bats](https://bats-core.readthedocs.io) test in
  `tests/`.
- What users see goes in the README, and in the `Unreleased` section of
  [CHANGELOG.md](CHANGELOG.md).
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org):
  `type(scope): description`, in the present tense and about 72 characters long. A body
  is only needed for what the diff does not say, such as a reason or a trade-off.
- A pull request covers one topic, and CI must pass on macOS and Ubuntu.

## Releases

Versions follow [Semantic Versioning](https://semver.org). A release is an annotated tag
`vX.Y.Z` on `main`, whose message holds the version's section of the changelog.

1. In `CHANGELOG.md`, rename `Unreleased` to the version and its date, add a new empty
   `Unreleased` section and update the links at the bottom. Commit and push to `main`.
2. Create the tag. The script checks that `main` is clean and matches `origin/main`:

   ```bash
   scripts/release tag v0.2.0
   ```

3. Push it:

   ```bash
   git push origin v0.2.0
   ```

The Release workflow then checks the tag, runs CI, and publishes a GitHub release with
the changelog section as its notes.

## License

Contributions are released under the [MIT License](LICENSE), like the rest of bivy.
