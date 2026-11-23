# Sample profile

A povy profile is a Git repository in mise's own format. To start your own, copy
this directory to the root of a new repository, keep what you need, and set
`profile` to that repository in `config.toml`.

| File | What it holds |
| --- | --- |
| `team.toml` | What mise includes in every directory, through povy: the tools (jq, Node.js 22 and 20, Prettier from npm, Starship) and the `ll` alias. |
| `mise.toml` | What `mise bootstrap` applies: the `tree` package, the `SAMPLE_API_TOKEN` secret, `sample.conf` from a template, `starship.toml`, mise activation and a block in `.zshrc` and `.bashrc`. |
| `[_.povy]` in `mise.toml` | What povy does itself: the commands of `bin` on every PATH, and on Windows, the files and the PowerShell code. |
| `bin/` | `sample-hello`, and its `.ps1` twin for Windows. |
| `files/` | `sample.conf`, a template that reads the secret, and `starship.toml`. |
| `shell/` | `functions.sh` for zsh and bash, `aliases.ps1` for PowerShell. |

Everything in `team.toml` and `mise.toml` is [mise configuration](https://mise.jdx.dev/configuration.html)
and [mise bootstrap](https://mise.jdx.dev/bootstrap.html): read those pages for every
section. Things to know:

- Tools go in `team.toml`. The `[tools]` of `mise.toml` apply only in the profile's
  own directory.
- mise writes no file on Windows, so file entries carry `os = "unix"`. povy writes
  those that `[_.povy.windows]` lists, with only `secret()` and `vars` in templates.
- A file takes one block across every mise config: a profile's `~/.zshrc` block
  replaces one that the machine's own config declares for that file.

## Try it

Point a machine at this directory of the povy repository:

```toml
# ~/.config/povy/config.toml
name = "Ada Lovelace"
email = "ada@example.org"
profile = "https://github.com/Yodatek/povy.git"
profile_path = "_samples/profile"
```

Then run `povy apply`. The first run stops and asks you to fill `SAMPLE_API_TOKEN` in
`~/.config/povy/.env`. Any value will do; it only ends up in `sample.conf`. Run
`povy apply` again, then open a new terminal:

```bash
sample-hello
```

```bash
mise ls --current
```

Trying the sample changes your prompt, installs the tools and the package above, and
replaces `~/.config/starship.toml`: keep a copy of yours first. To stop using it,
remove `profile_path`, set `profile` back and run `povy apply`. What it installed
stays where it is.
