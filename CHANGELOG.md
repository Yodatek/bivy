# Changelog

The notable changes of each release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.2.0] - 2026-11-23

povy becomes a thin layer over mise: a profile is mise configuration that `mise bootstrap` applies, and povy keeps what mise leaves out. "From povy 0.1" in the README lists what to move.

### Added

- A preview of povy on Windows without WSL2, in PowerShell 7: `bootstrap.ps1`, and `povy init`, `apply`, `doctor` and `version` from the same configuration and profiles. Tools and profile commands go on the user `PATH`, the PowerShell profile gets a marked block, and povy writes the profile's files that mise does not write on Windows.
- `profile_ref`, a branch, a tag or a commit to pin the profile on. `profile_branch` stays as its old name.
- `povy doctor` checks the version of mise, that `mise bootstrap` has applied the profile, and that the profile's commands and `~/.local/bin` are on the `PATH` of a shell started without mise.

### Changed

- **Breaking.** A profile is now mise configuration: `team.toml`, which povy has mise include in every directory, and `mise.toml`, which `povy apply` runs `mise bootstrap` on. `[_.povy]` in `mise.toml` holds `bin` and what povy does on Windows.
- **Breaking.** Tools, packages and the prompt are mise configuration: `config.toml` no longer takes `[tools]`, `[packages]` or `prompt`, and stops with a message when it has them.
- Secrets of `.env` reach `mise bootstrap` through its environment.
- The banner shows the tools and the machine load, and leaves the checks to `povy doctor`.
- povy needs mise 2026.11 or later.

### Removed

- `povy tools`: `mise ls --current` lists the tools and where they come from.
- povy's own package installation, file templates and shell file loading on macOS and Linux: `mise bootstrap` does them, and povy still backs up a file before mise replaces it.

### Fixed

- The `env` block also goes in `~/.zshenv` when `ZDOTDIR` is set, so that a shell started without `ZDOTDIR` sees the shims.
- `doctor` no longer warns that tools are hidden, nor fails, when `mise activate` puts their directories before the shims.
- On Linux, graphical apps get the profile's commands too.
- On Windows, `doctor` compares the generated Git files and fails when `.env` is missing, and the user `PATH` is backed up before povy changes it.

## [0.1.0] - 2026-11-21

First release.

### Added

- `bootstrap`, which installs Git and mise when they are missing, clones the engine and links the `povy` command.
- `povy init`, `povy apply` and `povy doctor`. mise tools and their shims are on the `PATH` of zsh and bash, interactive or not, and of graphical apps on macOS and Linux.
- The Git identity from `config.toml`, and other identities by directory with `[[identities]]`.
- Profiles in a Git repository of their own, on a branch with `profile_branch` or in a directory with `profile_path`. A profile declares secrets, tools, templated files, commands with `bin`, shell files with `shell`, and system packages for brew, cask, apt and dnf with `[packages]`.
- Tool versions given as lists: every version is installed, the first one is the default.
- `povy banner` in each new terminal, quiet in IDEs and coding agents, and `povy tools`.
- An optional Starship prompt.
- A sample profile in `_samples/profile`.
- `povy --version`.

[Unreleased]: https://github.com/Yodatek/povy/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Yodatek/povy/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Yodatek/povy/releases/tag/v0.1.0
