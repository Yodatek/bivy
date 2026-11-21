# Security policy

## Supported versions

Fixes go to `main` and to the next release. Only the latest release is supported, so
update before you report: `povy --version` tells which one you run.

## Reporting a vulnerability

Report it privately through
[GitHub's private reporting form](https://github.com/Yodatek/povy/security/advisories/new),
never in a public issue, pull request or discussion. Include:

- what an attacker can do, and under which conditions;
- the steps to reproduce it, with the version and the system;
- a fix, if you have one.

The maintainers confirm the report, agree on a disclosure date with you, and credit you
in the advisory unless you prefer otherwise.

## Scope

povy handles secrets and writes in the home directory, so these are in scope:

- `.env`, generated files or backups readable by other users;
- a value from `config.toml`, `.env` or a profile that runs as code where it should not;
- a profile file written outside the home directory, or read from outside the profile;
- a secret that ends up in logs, command lines or a Git repository.

A profile is trusted by design: it installs tools and adds commands and shell code, as
the README says. That a malicious profile can run code is not a vulnerability.
