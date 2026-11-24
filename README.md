# povy

A portable development environment for macOS, Linux and Windows, through WSL2 or, in
preview, natively in PowerShell 7, built on [mise](https://mise.jdx.dev).

A team keeps its setup in a Git repository of mise configuration: tools, packages,
files, secrets. povy points mise at it and lets `mise bootstrap` apply it, then does
what mise leaves out: it keeps your real `HOME`, and puts the tools on the `PATH` of
every shell and graphical app, those started without mise on their `PATH` included,
so IDEs and coding agents see the same tools, SSH keys and config files you do.

One machine can serve several teams: a [context](#contexts) applies its own profile
and Git identity below a directory, such as `~/work/acme/`, and the IDEs and agents
opened there get it too.

<p align="center">
  <img src="docs/banner.png" width="720"
    alt="The povy banner: the POVY logo in a frame, gauges for CPU, memory and disk, and the tools with their versions">
</p>

```bash
curl -fsSL https://raw.githubusercontent.com/Yodatek/povy/main/bootstrap | bash
```

The bootstrap installs Git and mise if they are missing, clones the engine into
`~/.local/share/povy` and links the command at `~/.local/bin/povy`. On a terminal it
then offers to configure the machine. povy needs mise 2026.11 or later.

To update povy, run the same command again, then `povy apply`. The
[changelog](CHANGELOG.md) lists what each release changes, and `povy --version` tells
which one you run.

### Windows without WSL2 (preview)

In PowerShell 7:

```powershell
irm https://raw.githubusercontent.com/Yodatek/povy/main/bootstrap.ps1 | iex
```

This bootstrap installs Git and mise with winget if they are missing, clones the engine
into `%LOCALAPPDATA%\povy\engine` and adds the `povy` command to your user `PATH`. The
PowerShell engine reads the same `config.toml` and profiles, and offers `povy init`,
`apply`, `doctor`, `status` and `version`. What changes on Windows:

- The mise shims, the profile's commands and `~/.local/bin` go on the user `PATH`,
  which every new process gets, graphical apps included, and so does mise itself when
  the system `PATH` lacks it, since its shims run it. Windows puts the system `PATH`
  first, so a tool also installed for the whole machine wins outside PowerShell;
  `povy doctor` names it. PowerShell sessions put the shims first.
- Your PowerShell profile gets a marked block that sources the profile's PowerShell
  files.
- mise writes no file on Windows, so povy writes the files that the profile lists for
  Windows, with only `secret()` and `vars` in their templates.
- There is no banner yet.

## Commands

| Command | What it does |
| --- | --- |
| `povy init` | Asks for a name, an e-mail and an optional profile URL. Writes `~/.config/povy/config.toml` and `.env` in mode 600, and opens `.env` in `$EDITOR` only if the profile needs secrets that are still empty. |
| `povy init --config <file>` | The same without questions or editor, from an existing `config.toml`. |
| `povy apply` | Updates the profile, lets `mise bootstrap` apply it, puts the tools on the `PATH` of shells and graphical apps, and sets the Git identity. Running it again changes nothing. |
| `povy doctor` | Checks the real state and changes nothing, including what a shell started by an IDE sees. Exits 0 if all is well, 1 otherwise. |
| `povy banner` | Shows the tools and the CPU, memory and disk load. |
| `povy status [<dir>]` | Shows the contexts and `[[identities]]` entries that apply in a directory, the current one by default, the deepest first. |
| `povy version` | Shows the release povy is on, such as `0.2.0`, or `0.2.0-3-gabc1234` three commits after it. |

## Three levels

1. **The engine** is this repository. It holds nothing specific to a person or a company.
2. **A profile** is an optional, separate Git repository of mise configuration, usually
   a team's and private.
3. **The machine config** lives in `~/.config/povy/` and is never versioned. Your own
   mise configuration, `~/.config/mise/config.toml`, wins over the profile.

```toml
# ~/.config/povy/config.toml
name = "Ada Lovelace"
email = "ada@example.org"
profile = "git@example.org:team/workstation.git"
profile_ref = "v3"    # optional: a branch, a tag or a commit, else the default branch
profile_path = "dev"  # optional: the directory of the repository that holds the profile

[contexts.oss]        # optional: a Git identity, a profile, or both, below a directory
dir = "~/oss/"
email = "ada@users.noreply.github.com"
# name = "Ada"        # defaults to the name above
```

[Contexts](#contexts) explains them. The `[[identities]]` entries of povy 0.2 still
work: each one is a context with only an email.

A branch follows its remote at each `apply`, a tag is looked up again, and a commit
stays where it is: pin a tag or a commit to choose when a machine takes the team's
changes. A profile at a URL is cloned without the content of its history, which povy
never reads, so a repository with a heavy history costs no more than its files.

## Profiles

A profile is mise configuration in two files, at the root of its repository or in the
directory that `profile_path` names. [_samples/profile](_samples/profile) uses each part,
and its README shows how to try it on a machine.

| File | Read by | Holds |
| --- | --- | --- |
| `team.toml` | mise, in every directory: povy includes it from `~/.config/mise/conf.d/povy.toml` | `[tools]`, `[env]`, `[shell_alias]`, `[vars]`: what an [included file](https://mise.jdx.dev/configuration.html#include) accepts |
| `mise.toml` | `mise bootstrap`, which povy runs on the profile | [bootstrap](https://mise.jdx.dev/bootstrap.html) sections: packages, secrets, files, shell activation, LaunchAgents |
| `[_.povy]` in `mise.toml` | povy; mise ignores `[_]` | `bin`, and what povy does on Windows |

```toml
# mise.toml: what povy does itself
[_.povy]
bin = "bin"   # commands that povy puts on the PATH of every shell and graphical app

[_.povy.windows]
files = ["~/.m2/settings.xml"]   # [bootstrap.files] that povy writes on Windows
shell = ["shell/team.ps1"]       # PowerShell files that interactive sessions source
```

Secrets come from `~/.config/povy/.env`. `povy init` adds a line for each secret of
`[bootstrap.secrets]` that a template of the profile reads, and `povy apply` gives their
values to `mise bootstrap` in its environment, never on a command line. A secret set in
the environment, by [fnox](https://fnox.jdx.dev) for instance, works too.

`bin` is read in place from the profile clone, so a command added to the profile is
there after the next `apply`. Windows runs its `.ps1` and `.cmd` files, the other systems
its executable scripts.

A profile can install tools and packages, write files in your home directory and run
commands in your shells, so only use one you trust.

## Contexts

A context applies a profile, a Git identity, or both, below a directory. Contexts let
one machine serve several teams, each with its own tools, variables, secrets and
identity, in the real home directory:

```toml
[contexts.acme]
dir = "~/work/acme/"
email = "ada@acme.example"

[contexts.product]            # inside acme: the deepest context wins
dir = "~/work/acme/product/"
profile = "git@git.acme.example:product/workstation.git"
profile_ref = "main"

[contexts.solo]
dir = "~/solo/"
email = "ada@users.noreply.github.com"
```

For a context with a profile, `povy apply` clones it and writes
`<dir>/.config/mise/conf.d/povy.toml`, which includes its `team.toml`, then has mise
trust that file. mise applies the team's tools and `[env]` to every directory below,
nested contexts adding up and the deepest winning, and so do the shims that IDEs and
agents run. `mise bootstrap` applies the profile's `mise.toml` as for the default
profile, the profile's commands go on every `PATH`, and the context's identity
applies to the repositories below its directory. `povy status` shows which contexts
apply where.

The secrets of a context come from `~/.config/povy/<id>.env`, then from the shared
`.env`, and `apply` adds those it lacks to `<id>.env`. A context removed from
`config.toml` takes its mise config and its clone along at the next `apply`; its
`.env` stays.

A profile meant for a context follows a few rules:

- Files are machine-wide. `apply` stops when two profiles write the same file, the
  default profile included, unless each writes a block of its own `id` into it.
  Write a context's own files to its own paths, and point the tools at them from
  `[env]`:

  | Tool | Variable |
  | --- | --- |
  | kubectl, Helm | `KUBECONFIG` |
  | npm | `NPM_CONFIG_USERCONFIG` |
  | Maven 3.9 | `MAVEN_ARGS`, such as `--settings=…` |
  | Docker | `DOCKER_CONFIG` |
  | GitHub CLI | `GH_CONFIG_DIR` |
  | Ansible | `ANSIBLE_CONFIG` |
  | Starship | `STARSHIP_CONFIG` |

- Blocks in rc files run in every shell, so they only call commands that exist
  everywhere, such as the tools of your own mise config.
- In a shell without `mise activate`, only the tools that mise runs through its shims
  get the context's `[env]`: install with mise the tools that read those variables.
- When two profiles have a command of the same name, the first in `config.toml`
  wins, and `apply` and `doctor` say so.

To move the default profile to a context, first add the commands its rc blocks call to
your own mise config, naming the file: while the default profile provides a tool,
`mise use -g` writes it into povy's `~/.config/mise/conf.d/povy.toml`, which `apply`
rewrites.

```bash
mise use --path ~/.config/mise/config.toml starship
```

Then move `profile`, `profile_ref` and `profile_path` into a `[contexts.<id>]` table, and
run `povy apply`, which removes the former clone.

## Banner

Each new terminal shows the banner above: who and where, gauges for the CPU, memory and
disk load, and the tools mise provides. A terminal narrower than 80 columns, or without
UTF-8, gets the same on a few lines. It reports only what costs nothing more to know, a
tool not installed or a disk almost full; `povy doctor` makes the thorough checks.

It stays quiet in a shell that is not interactive or does not write to a terminal, which
covers scripts, SSH commands, and IDEs reading the shell environment. It also stays quiet
in the terminals of VS Code and its forks, Zed, JetBrains IDEs, Emacs and Claude Code.

| To | Do |
| --- | --- |
| hide it in one shell | `POVY_BANNER=0` |
| show it where it keeps quiet | `POVY_BANNER=1` |
| turn it off on the machine | `banner = false` in `config.toml`, then `povy apply` |

## What apply changes

- `~/.config/mise/conf.d/povy.toml` is generated: it includes the profile's `team.toml`.
  Your `~/.config/mise/config.toml` is not touched.
- For each context with a profile, `<dir>/.config/mise/conf.d/povy.toml` is generated,
  the clone lives in `~/.local/state/povy/contexts/<id>/`, and the secrets in
  `~/.config/povy/<id>.env`.
- `mise bootstrap` applies the profile's `mise.toml`, as its documentation describes.
- Marked blocks in the startup files source `~/.config/povy/env.sh`, which puts the
  shims, the profile's commands and `~/.local/bin` on PATH by absolute path, and
  `~/.config/povy/interactive.sh`, which shows the banner:
  - `env` sits at the top of `~/.zshenv`, of `$ZDOTDIR/.zshenv` when you set `ZDOTDIR`,
    and of `.bashrc`, and at the bottom of `.zprofile` and your bash login file, after
    what they add to PATH, such as `brew shellenv`;
  - `interactive` sits at the bottom of `.zshrc`, `.bashrc` and your bash login file.

  The rest of each file is kept, and a symlinked dotfile stays a symlink.
- Graphical apps get the same `PATH`:
  - on macOS, the LaunchAgent `~/Library/LaunchAgents/povy.env.plist` runs
    `launchctl setenv PATH` at each login, and `apply` runs it once right away;
  - on Linux, `~/.config/environment.d/50-povy.conf` is read by systemd from the next
    login.
- `~/.config/povy/git/` is generated, and a marked block at the top of `~/.gitconfig`
  includes it. `~/.config/git/config` gets the block instead when it is the only global
  Git config.
- Anything povy replaces is first copied to `~/.local/state/povy/backups/<date>/`, and so
  is a file that `mise bootstrap` is about to replace with the profile's.

## Git identity

`name` and `email` become your Git identity. Each context with an `email`, and each
`[[identities]]` entry, replaces it in the repositories under its directory, through
`includeIf "gitdir:..."`; in nested directories the deepest wins. The directory starts
with `~/` or `/`.

povy includes its generated config from the top of your global Git config, so what you
wrote below keeps precedence. A `[user]` there wins over every identity povy sets, even
in an identity directory, so `apply` and `doctor` name the file that holds one.

## From povy 0.1

povy 0.2 hands tools, packages, files and the prompt to mise. `apply` and `init` stop
with a message on what 0.1 read:

- In `config.toml`, `[tools]`, `[packages]` and `prompt` move to your own mise
  configuration; `profile_branch` still works, as the old name of `profile_ref`.
- A profile's `profile.toml` becomes `team.toml` and `mise.toml`: `[tools]` go to
  `team.toml`; `[packages]`, `[secrets]` and `[[files]]` become `[bootstrap.packages]`,
  `[bootstrap.secrets]` and `[bootstrap.files]`, with templates in mise's syntax, such
  as `{{ secret(name="token") }}`; `bin` moves to `[_.povy]`; `shell` and `prompt`
  become blocks in the rc files, or `[_.povy.windows] shell` on Windows.

## Known limits

- A `bash -c` started with an empty environment reads no startup file, so nothing can put
  the shims on its `PATH`. It inherits `PATH` from its parent, and `bash -lc` works.
- mise shims refuse to run under a directory holding an untrusted `mise.toml`. Run
  `mise trust` in that project.
- On macOS, apps already running keep their `PATH` until restarted, and apps reopened at
  login may start before the LaunchAgent. macOS announces the agent as a background item.
  If you turn it off in Login Items, `doctor` warns that graphical apps do not see the
  shims.
- On Linux, graphical apps get the shims only in a session started by systemd.
- fish is not supported yet.
- Native Windows is a preview: it has no banner, and it is tested on GitHub's Windows
  runners rather than on many machines.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) explains the setup, the tests and how releases are
made, and [SECURITY.md](SECURITY.md) how to report a vulnerability. Everyone who takes
part follows the [code of conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE)
