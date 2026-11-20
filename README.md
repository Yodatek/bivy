# bivy

A portable development environment for macOS, Linux and Windows through WSL2.

bivy keeps your real `HOME`. Tools come from [mise](https://mise.jdx.dev), and their
shims are on `PATH` in interactive and non-interactive shells alike, and in graphical
apps, so IDEs and coding agents see the same tools, SSH keys and config files you do.

```bash
curl -fsSL https://raw.githubusercontent.com/Yodatek/bivy/main/bootstrap | bash
```

The bootstrap installs Git and mise if they are missing, clones the engine into
`~/.local/share/bivy` and links the command at `~/.local/bin/bivy`. On a terminal it
then offers to configure the machine.

## Commands

| Command | What it does |
| --- | --- |
| `bivy init` | Asks for a name, an e-mail and an optional profile URL. Writes `~/.config/bivy/config.toml` and `.env` in mode 600, and opens `.env` in `$EDITOR` only if the profile needs secrets that are still empty. |
| `bivy init --config <file>` | The same without questions or editor, from an existing `config.toml`. |
| `bivy apply` | Installs the tools, puts the shims on the `PATH` of shells and graphical apps, sets the Git identity and writes the profile files. Running it again changes nothing. |
| `bivy doctor` | Checks the real state and changes nothing. Exits 0 if all is well, 1 otherwise. |
| `bivy banner` | Shows the tools, what does not work right now, and the CPU, memory and disk load. |

## Three levels

1. **The engine** is this repository. It holds nothing specific to a person or a company.
2. **A profile** is an optional, separate Git repository, usually private.
3. **The machine config** lives in `~/.config/bivy/` and is never versioned.

```toml
# ~/.config/bivy/config.toml
name = "Ada Lovelace"
email = "ada@example.org"
profile = "git@example.org:me/my-profile.git"

[tools]            # optional, overrides the profile
node = "22"

[[identities]]     # optional, another Git identity under a directory
dir = "~/oss/"
email = "ada@users.noreply.github.com"
# name = "Ada"     # defaults to the name above
```

## Git identity

`name` and `email` become your Git identity. Each `[[identities]]` entry replaces it in
the repositories under its directory, through `includeIf "gitdir:..."`. The directory
starts with `~/` or `/`.

bivy includes its generated config from the top of your global Git config, so what you
wrote below keeps precedence. A `[user]` there wins over every identity bivy sets, even
in an identity directory, so `apply` and `doctor` name the file that holds one.

## Profiles

A profile has a `profile.toml` at its root. See [examples/profile](examples/profile).

```toml
[secrets]
required = ["EXAMPLE_API_TOKEN"]   # read from ~/.config/bivy/.env

[tools]
jq = "1.7.1"
java = ["21", "25"]                 # all installed, the first one is the default

[[files]]
source = "files/example.conf.tmpl"          # relative to the profile
target = ".config/bivy-example/example.conf" # relative to the home directory
```

Files are written in mode 600. Templates can use `{{name}}`, `{{email}}`, `{{home}}` and
`{{SECRET}}` for each required secret. An unknown placeholder stops `apply` before
anything is written.

A profile can install tools and write files in your home directory, so only use one you
trust.

## Banner

Each new terminal shows a short banner: who and where, the CPU, memory and disk load,
the tools mise provides, then `all good` or one line per problem. It only makes checks
that take no time, such as empty secrets, missing files, a config changed since the
last `apply` or a tool not installed. `bivy doctor` makes the thorough ones.

It stays quiet in a shell that is not interactive or does not write to a terminal, which
covers scripts, SSH commands, and IDEs reading the shell environment. It also stays quiet
in the terminals of VS Code and its forks, Zed, JetBrains IDEs, Emacs and Claude Code.

| To | Do |
| --- | --- |
| hide it in one shell | `BIVY_BANNER=0` |
| show it where it keeps quiet | `BIVY_BANNER=1` |
| turn it off on the machine | `banner = false` in `config.toml`, then `bivy apply` |

## What apply changes

- `~/.config/mise/conf.d/bivy.toml` is generated. Your `~/.config/mise/config.toml` is
  not touched.
- A marked block at the top of `.zshenv`, `.zprofile`, `.bashrc` and your bash login file
  sources `~/.config/bivy/env.sh`, and the one in `.zshrc`, `.bashrc` and the bash login
  file sources `~/.config/bivy/interactive.sh`, which shows the banner. The rest of each
  file is kept, and a symlinked dotfile stays a symlink.
- Graphical apps get the same `PATH`:
  - on macOS, the LaunchAgent `~/Library/LaunchAgents/bivy.env.plist` runs
    `launchctl setenv PATH` at each login, and `apply` runs it once right away;
  - on Linux, `~/.config/environment.d/50-bivy.conf` is read by systemd from the next
    login.
- `~/.config/bivy/git/` is generated, and a marked block at the top of `~/.gitconfig`
  includes it. `~/.config/git/config` gets the block instead when it is the only global
  Git config.
- Anything replaced is first copied to `~/.local/state/bivy/backups/<date>/`.

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

## Development

Tests, lint and the secret scan run with mise; each test gets a temporary `HOME`. CI
runs them on macOS and Ubuntu.

```bash
mise trust
```

```bash
mise run test
```

```bash
mise run lint
```

Before each push, a hook scans the history for secrets with gitleaks. Enable it once
per clone:

```bash
git config core.hooksPath .githooks
```

The code targets bash 3.2, the version macOS ships.

## License

[MIT](LICENSE)
