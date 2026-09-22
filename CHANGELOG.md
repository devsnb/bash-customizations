# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
What the numbers mean here is spelled out under
[Releases](README.md#releases) — in short, **major** means an alias, function or
flag was renamed or removed, so your muscle memory needs updating.

## [Unreleased]

### Changed

- Managed binaries are downloaded into a staging directory, checked for the
  pinned version, and atomically renamed into place instead of being extracted
  over a live executable.
- Existing commands elsewhere on `PATH` no longer suppress the pinned
  `~/.local/bin` installation. Conflicting unowned files at the managed path
  require an explicit `--force` before setup replaces and claims them.
- Tool-release discovery accepts `GITHUB_TOKEN` or `GH_TOKEN`, uses GitHub's
  versioned JSON API, and reports rate-limit failures with an actionable fix.

### Fixed

- `uninstall.sh --purge-tools` now removes only tools whose ownership, version,
  and installed-file hash were recorded by `setup.sh`; unrelated same-name
  binaries and legacy `~/.fzf` directories are preserved.
- `setup.sh --skip-tools` no longer requires `tools.lock`, a downloader, archive
  utilities, tool verification, or locale setup merely to repair dotfiles.
- Release preparation no longer runs the complete Docker round trip twice just
  to determine whether Docker was skipped.

## [1.1.0] - 2026-09-20

### Added

- Reproducible installs for Starship, fzf, zoxide and ble.sh: `tools.lock`
  records exact versions and SHA-256 hashes for Linux and macOS on x86-64 and
  ARM64, and `setup.sh` refuses unverified bytes.
- `make tools-outdated`, `make tools-lock` and `make tools-update` for reviewing,
  reproducing and advancing the pinned tool set.
- Dependabot updates for the GitHub Actions used by CI, and unit coverage for
  lock completeness, platform mapping, checksum rejection and partial updates.
- `ports`, a portable `ss`/`lsof` function replacing the Linux-only alias, and
  advisory `doctor.sh` checks for optional commands used by shell helpers.

### Changed

- fzf and zoxide now install from verified release archives instead of a moving
  git branch or remote installer script; Starship no longer pipes a downloaded
  installer into a shell.
- `extract` reports missing decompressors consistently for common and uncommon
  archive formats, and `psa` uses syntax supported by macOS.

### Fixed

- Release preparation preserves the normal `0644` permissions of `VERSION` and
  `CHANGELOG.md` after replacing their temporary files.

## [1.0.1] - 2026-08-24

### Added
- [`docs/RELEASING.md`](docs/RELEASING.md) — the maintainer's guide to cutting a
  release: what each of `make release`'s refusals means, what CI does with the
  tag, and how to recover when something goes wrong.

### Changed
- The README's release section now points at that guide instead of describing
  the process a second time, and **patch** is documented as covering
  documentation and internal changes, not just fixes.

## [1.0.0] - 2026-08-22

The first tagged release. Everything below already existed on `main`; this entry
is the record of it, and of what changed for anyone who cloned before there were
tags to check out.

### Added

- `cheatsheet` — lists every alias and function with a description, grouped by
  category. `cheatsheet git` filters. It reads the deployed `~/.bash/` copies, so
  it works without the repo present, and marks entries whose optional tool
  (`eza`, `docker`) is missing on this machine.
- A test suite: `make test-unit` (module behaviour and argument handling) and
  `make test-docker` (a full install → doctor → uninstall → restore round trip in
  three container environments — a user with sudo, a user without, and root
  without a `sudo` binary at all). `make check` runs everything CI runs.
- `make docs` regenerates the README's alias and function tables from the source
  comments, and `make docs-check` fails if they have gone stale. An alias without
  a description now fails the build rather than shipping undocumented.
- Backup management in `uninstall.sh`: `--list-backups`, `--restore=TIMESTAMP`,
  `--restore-only`, `--prune-backups[=N]`, `--delete-backup=TS`, and `--yes` for
  running without a terminal.
- `--version` on `setup.sh`, `doctor.sh` and `uninstall.sh`, a `VERSION` file, and
  a `VERSION=` line in the install manifest — so a machine can say which release
  deployed its dotfiles. `doctor.sh` reports it and says when the repo is newer.
- `NO_COLOR` support and automatic plain output when stdout is not a terminal, so
  `doctor.sh > report.txt` no longer writes escape sequences. ASCII fallbacks
  replace the box-drawing and check-mark glyphs outside a UTF-8 locale.

### Changed

- **BREAKING** — aliases and functions renamed so their names say what they do:

  | Old | New | Why |
  |---|---|---|
  | `duf` | `du-files` | `duf` is a real disk-*free* tool; this is the opposite |
  | `dud` | `du-dirs` | matches its sibling |
  | `tre` | `tree-all` | `tre` is a real tree replacement |
  | `bak` | `backup-file` | reads as a noun, but it is a verb |
  | `find-in` | `grep-in` | it is `grep -rn`, not `find` |
  | `aliases` | `edit-aliases` | it opens an editor; the old name sounds like it lists them |

- **BREAKING** — `fkill`'s argument is now a name filter, with the signal moved
  behind `-s`. `fkill nginx` used to expand to `kill -nginx`; it now does what it
  looks like. It also confirms the process before killing it.
- **BREAKING** — `make purge` is now `make purge-tools`, matching the
  `--purge-tools` flag.
- `make update` now fetches the newest release *and* re-deploys; the previous
  tools-only behaviour moved to `make update-tools`.
- `doctor.sh` separates failures from warnings and exits `0` when only warnings
  are present, matching what the README always said. Warnings are advisory.
- `$EDITOR` defaults to `nano` rather than `nvim`.

### Removed

- **BREAKING** — the `vi`, `cat` and `less` aliases. They shadowed the real
  tools: `vi` opened `$EDITOR`, and `cat`/`less` became `bat`, which does not
  accept `cat -A/-v/-e` or `less +F/-N/-S`. `bat` is still there under its own
  name. `v` remains as a shortcut to `$EDITOR`.
- The Neovim configuration and the tree-sitter CLI plumbing.

### Fixed

- `uninstall.sh --restore` could not restore `~/.bashrc` — the one file the tool
  cannot rebuild — because it skipped any destination that was not a symlink,
  while still reporting success. It now restores it and snapshots whatever it
  replaces into `~/.bash_backup/<ts>-pre-restore/` first.
- A mistyped `--restore=TIMESTAMP` used to strip the install *before* discovering
  the backup did not exist. The timestamp is now validated before anything is
  touched.
- `uninstall.sh` with no terminal and no `--yes` printed "Aborted." and exited
  `0` — a failed run reporting success. It now exits `1`.
- `--dry-run` announced removals it had not made (`[DRY] rm …` immediately
  followed by `[OK] Removed: …`).
- `setup.sh` aborted on machines without `sudo`, including containers running as
  root, because `sudo` was invoked bare under `set -e`.
- `~/.bashrc` was silently tightened to mode 600 on every run, because rewrites
  went through `mktemp` and `mv` carried its mode across.
- A second `setup.sh` blanked the manifest's `BACKUP=` pointer, quietly
  downgrading `--restore` to "whatever is newest on disk".
- `extract` blamed a missing tool when extraction merely failed, and `myip`'s
  "(unavailable)" fallback could never fire.
- A module removed from the repo left a dangling symlink in `~/.bash` that
  dropped out of the manifest and survived even a full uninstall.
- Upgrading took no new `~/.bashrc` backup, so a release that changed the managed
  block could only be undone all the way back to the pre-install state.

[Unreleased]: https://github.com/devsnb/bash-customizations/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/devsnb/bash-customizations/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/devsnb/bash-customizations/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/devsnb/bash-customizations/releases/tag/v1.0.0
