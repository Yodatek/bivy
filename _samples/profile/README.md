# Sample profile

A povy profile that uses every key of `profile.toml`. To start your own, copy this
directory to the root of a new Git repository, keep what you need, and set `profile` to
that repository in `config.toml`.

| Key | Here |
| --- | --- |
| `prompt` | Starts Starship, whose look comes from `files/starship.toml`. |
| `bin` | Puts `sample-hello` on `PATH`. |
| `shell` | Adds the `ll` alias and the `mkcd` function to interactive shells. |
| `[secrets]` | Needs `SAMPLE_API_TOKEN` in `~/.config/povy/.env`. |
| `[tools]` | Installs jq, and Node.js 22 and 20 with 22 as the default. |
| `[packages]` | Installs `tree` with brew, apt or dnf, whichever the machine has. |
| `[[files]]` | Writes `~/.config/povy-sample/sample.conf` and `~/.config/starship.toml`. |

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
povy tools
```

Trying the sample changes your prompt and installs the tools and packages above. Files
it replaces, such as an existing `~/.config/starship.toml`, are first copied to
`~/.local/state/povy/backups/`. To stop using it, remove `profile_path`, set `profile`
back and run `povy apply`. The files and packages it added stay where they are.
