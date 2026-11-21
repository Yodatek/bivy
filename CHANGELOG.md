# Changelog

The notable changes of each release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.1.0] - 2026-11-21

First release.

### Added

- `bootstrap`, which installs Git and mise when they are missing, clones the engine and links the `bivy` command.
- `bivy init`, `bivy apply` and `bivy doctor`. mise tools and their shims are on the `PATH` of zsh and bash, interactive or not, and of graphical apps on macOS and Linux.
- The Git identity from `config.toml`, and other identities by directory with `[[identities]]`.
- Profiles in a Git repository of their own, on a branch with `profile_branch` or in a directory with `profile_path`. A profile declares secrets, tools, templated files, commands with `bin`, shell files with `shell`, and system packages for brew, cask, apt and dnf with `[packages]`.
- Tool versions given as lists: every version is installed, the first one is the default.
- `bivy banner` in each new terminal, quiet in IDEs and coding agents, and `bivy tools`.
- An optional Starship prompt.
- A sample profile in `_samples/profile`.
- `bivy --version`.

[Unreleased]: https://github.com/Yodatek/bivy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Yodatek/bivy/releases/tag/v0.1.0
