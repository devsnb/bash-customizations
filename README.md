# bash-customizations

A clean, modular Bash setup built around five best-in-class shell tools.

Once installed, run **`cheatsheet`** in your shell to see everything it added.

```/dev/null/tree.txt#L1-13
~
├── .bashrc                  ← thin orchestrator (load order only)
├── .blerc                   ← ble.sh config + fzf integration
├── .bash/
│   ├── exports.sh           ← PATH, env vars, FZF_* options
│   ├── history.sh           ← large persistent history, dedup, timestamps
│   ├── completion.sh        ← bash-completion v2, readline tweaks
│   ├── init.sh              ← fzf (readline mode) + zoxide init
│   ├── bindings.sh          ← key bindings (arrow history search, etc.)
│   ├── functions.sh         ← utility shell functions
│   ├── aliases.sh           ← aliases (ls, git, docker, …)
│   ├── prompt.sh            ← Starship init + fallback PS1
│   └── help.sh              ← the `cheatsheet` command
└── starship.toml            ← Starship config (symlinked → ~/.config/)
```

---

## Contents

- [Repository layout](#repository-layout) · [Tools](#tools) · [Scripts](#scripts)
- [Prerequisites](#prerequisites) · [Quick start](#quick-start) · [Script flags](#script-flags)
- [Uninstalling](#uninstalling) · [Diagnosing a broken setup](#diagnosing-a-broken-setup) · [Troubleshooting](#troubleshooting)
- [Recovery reference](#recovery-reference) · [How backups work](#how-backups-work)
- [Load order](#load-order) · [ble.sh + fzf: the keymap split](#blesh--fzf-the-keymap-split)
- [Module reference](#module-reference) — the full alias and function tables
- [Customisation](#customisation) · [Adding a new module](#adding-a-new-module) · [Updating tools](#updating-tools)
- [Testing](#testing) · [Releases](#releases) · [Contributing](#contributing)

---

## Repository layout

Files inside `bash/` are symlinked as `~/.bash/`; `.blerc` and `starship.toml` are symlinked into the expected dotfile locations. The three root-level scripts stay at the repo root so they can always be run with `bash <script>.sh` from any directory.

**`~/.bashrc` is never replaced.** Instead, `setup.sh` injects two clearly marked blocks into your existing `~/.bashrc`:

```
# === BEGIN bash-customizations ===
# ... ble.sh Part 1 + all module sources ...
# === END bash-customizations ===

# (your existing content is preserved above and below)

# === BEGIN bash-customizations-attach ===
[[ ${BLE_VERSION:-} ]] && ble-attach
# === END bash-customizations-attach ===
```

The HEAD block is inserted immediately after your non-interactive guard (or prepended if none exists). The TAIL block is appended at the end. Re-running `setup.sh` updates the blocks in-place without touching anything outside them. Every module setting lives in its own file under `bash/` so individual modules can be tested with `source ~/.bash/<module>.sh` without restarting the shell.

The install manifest (`~/.local/share/bash-customizations/manifest`) is a **generated runtime artifact** — it is written by `setup.sh`, never committed to git. It records the repo path, the backup directory used, and every symlink created. `uninstall.sh` and `doctor.sh` read it; if it is absent they fall back to a hardcoded default list. Previous manifests are kept as `manifest.<timestamp>.bak` (last 5 retained).

---

## Tools

| Tool | Installed from | Purpose |
|---|---|---|
| [starship](https://starship.rs) | pinned release asset | Cross-shell prompt with git, language, and time info |
| [ble.sh](https://github.com/akinomyoga/ble.sh) | pinned dated nightly | Syntax highlighting, smart completion, auto-suggestions |
| [bash-completion](https://github.com/scop/bash-completion) | system package manager | Tab-completion ecosystem for hundreds of CLI tools |
| [fzf](https://github.com/junegunn/fzf) | pinned release asset | Fuzzy file finder — CTRL-T, CTRL-R, ALT-C |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | pinned release asset | Frecency-ranked directory jumper (`z`, `zi`) |

The exact versions and SHA-256 hashes are committed in [`tools.lock`](tools.lock).
`setup.sh` refuses a missing, malformed, or mismatched hash, so separate machines
using the same checkout install the same bytes. Run `bash doctor.sh` to see the
versions actually installed on your system.

---

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Install tools + deploy dotfiles (idempotent) |
| `uninstall.sh` | Remove symlinks, restore backups, purge tools |
| `doctor.sh` | Diagnose a broken setup, suggest fixes |

---

## Prerequisites

| Requirement | Why | How to check |
|---|---|---|
| Bash ≥ 4.2 | associative arrays, `[[ ]]` features | `bash --version` |
| `curl` or `wget` | downloading tools | `command -v curl` |
| `tar`, `gzip`, `xz` | unpacking verified release archives | `command -v tar gzip xz` |
| `git` *(optional)* | only for `make update` | `command -v git` |
| **en_US.UTF-8 locale** | **ble.sh needs it — missing locale causes garbage in prompt** | `locale -a \| grep en_US` |
| `make` *(optional)* | only for the `make` targets below — `bash setup.sh` does the same job | `command -v make` |

**Keep the clone where it is.** Every deployed file is a symlink back into this
repository, so moving or deleting it after install breaks your shell config. If you
do move it, re-run `bash setup.sh --skip-tools` from the new location.

All three scripts exit `0` on success and `1` on failure. `doctor.sh` exits `0` when
there are no failures even if it printed warnings — warnings are advisory, so it is
safe to gate CI on `bash doctor.sh --quiet`.

### Install the locale (WSL / Ubuntu / Debian)

This is the most common setup issue. If the locale is missing, ble.sh falls back to single-byte mode and terminal escape sequences leak into the readline buffer as literal text (`>0;10;1c 2;1R` etc.).

```/dev/null/locale-fix.sh#L1-4
sudo apt-get install -y locales
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8
# open a new terminal
```

`setup.sh` detects and runs this automatically on Debian/Ubuntu/WSL systems.

---

## Quick start

```sh
git clone https://github.com/devsnb/bash-customizations.git
cd bash-customizations
make install      # full install + dotfile deployment
# Open a new terminal
```

Run `make` (or `make help`) to see all available targets:

| Target | Effect |
|---|---|
| `make install` | Install all tools + deploy dotfiles |
| `make dotfiles` | Deploy dotfiles only (tools already installed) |
| `make update` | Fetch the newest release, then re-install tools and dotfiles |
| `make update-tools` | Reinstall the tool versions pinned by this checkout |
| `make version` | Show this checkout's version and the one currently installed |
| `make dry-run` | Preview what install would do without making changes |
| `make doctor` | Diagnose the setup and show fix instructions |
| `make doctor-quiet` | Same, printing only failures and warnings |
| `make uninstall` | Remove managed symlinks and blocks from `~/.bashrc` |
| `make uninstall-dry` | Preview exactly what uninstall would remove |
| `make restore` | Uninstall and restore a backup — `BACKUP=<timestamp>` to pick one |
| `make restore-only` | Restore a backup **without** uninstalling |
| `make purge-tools` | Uninstall and remove all tool binaries |
| `make list-backups` | List available backups |
| `make prune-backups` | Delete all but the newest backups — `KEEP=<n>` (default 5) |
| `make lint` | `bash -n` + shellcheck every script |
| `make docs` | Regenerate the README alias/function tables from `bash/*.sh` |
| `make docs-check` | Fail if those tables are stale |
| `make tools-outdated` | Check whether newer managed-tool releases exist |
| `make tools-lock` | Re-download and verify the versions already in `tools.lock` |
| `make tools-update` | Pin and hash the newest release of every managed tool |
| `make test-unit` | Module behaviour and argument handling — no container needed |
| `make test-docker` | The full install → doctor → uninstall → restore round trip |
| `make test` | Unit tests + the container round trip |
| `make check` | Lint, docs, and test — what CI runs |
| `make release-dry` | Preview cutting a release — `VERSION=X.Y.Z` |
| `make release` | Cut a release locally: stamp, changelog, commit, tag |

You can also invoke the scripts directly if you prefer:

### Script flags

**`setup.sh`**

| Flag | Effect |
|---|---|
| *(none)* | Install all tools + deploy dotfiles |
| `--dry-run` | Show what would happen, change nothing |
| `--skip-tools` | Deploy dotfiles only (tools already installed) |
| `--force` | Re-install tools even if already present |
| `-V`, `--version` | Print the version and exit |
| `-h`, `--help` | Print usage, examples, and recovery hints, then exit |

**`uninstall.sh`**

| Flag | Effect |
|---|---|
| *(none)* | Remove managed symlinks and the `~/.bashrc` blocks |
| `--dry-run` | Show what would happen, change nothing |
| `-y`, `--yes` | Answer every prompt with yes — **required when there is no terminal** |
| `--restore` | Uninstall, then restore a backup |
| `--restore=TIMESTAMP` | Restore a specific backup (see `--list-backups`) |
| `--restore-only[=TS]` | Restore a backup *without* uninstalling |
| `--purge-tools` | Also remove tool binaries (starship, fzf, zoxide, ble.sh) |
| `--list-backups` | List available backups and exit |
| `--prune-backups[=N]` | Delete all but the newest N backups (default 5) and exit |
| `--delete-backup=TS` | Delete one backup and exit |
| `-V`, `--version` | Print the version and exit |
| `-h`, `--help` | Print usage and exit |

**`doctor.sh`**

| Flag | Effect |
|---|---|
| *(none)* | Run every check and print the results |
| `-q`, `--quiet` | Print only failures and warnings |
| `-V`, `--version` | Print the version and exit |
| `-h`, `--help` | Print usage, the check list, and exit codes |

To move to the newest release of this repository, run `make update` — it fetches
the checkout and then installs the versions pinned by that release. To reinstall
this checkout's pinned tools, use `make update-tools` (or `bash setup.sh --force`).
Maintainers can advance the pins with `make tools-update`; see
[Updating tools](#updating-tools).

---

## Uninstalling

```sh
make uninstall-dry                              # preview exactly what would be removed
make restore                                    # remove symlinks + restore your backup
make restore BACKUP=20250604_142301             # restore one specific backup
make purge-tools                                # also remove tool binaries

# Or with the script directly:
bash uninstall.sh --dry-run                     # preview what would be removed
bash uninstall.sh --list-backups                # show available timestamps
bash uninstall.sh --restore=20250604_142301     # restore a specific backup
bash uninstall.sh --restore-only=20250604_142301  # restore without uninstalling
bash uninstall.sh --restore --purge-tools       # full removal including binaries
bash uninstall.sh --yes                         # no prompts (scripts, CI, ssh)
```

**Which backup does `--restore` pick?** The one recorded in the install manifest —
the run that produced your current setup — and only if that is gone does it fall
back to the newest on disk. Pass `--restore=TIMESTAMP` to be explicit.

**Safety guarantees of `uninstall.sh`:**
- Removes only the two managed blocks from `~/.bashrc`; all other content is untouched
- Reads the install manifest to know *exactly* which symlinks `setup.sh` created
- Verifies each symlink points back into this repo before touching it
- Falls back to a hardcoded default list if no manifest exists
- Never removes system packages (`bash-completion` stays)
- Always asks for confirmation before removing anything, and again before `--purge-tools`
- Without a terminal to ask, it **exits 1 instead of doing nothing quietly** — pass `--yes` to proceed
- Validates a `--restore=TIMESTAMP` *before* touching anything, so a typo cannot leave a half-uninstalled shell
- A restore replaces real files (including `~/.bashrc`) and snapshots whatever it overwrites into `~/.bash_backup/<ts>-pre-restore/`

---

## Diagnosing a broken setup

```/dev/null/doctor-examples.sh#L1-5
# Full diagnostics
bash doctor.sh

# Failures only (good for CI or scripting)
bash doctor.sh --quiet
echo "Exit: $?"   # 0 = no failures, 1 = one or more failures
```

**Exit codes.** `0` means nothing is broken; `1` means at least one check failed.
Warnings — a missing non-interactive guard, an optional package, a shell that
predates the install — are advisory and never change the exit code, so
`doctor.sh` is safe to gate a script on.

`doctor.sh` checks **12 things** and prints a `→ Fix:` instruction for every failure:

| # | Check |
|---|---|
| 1 | Bash version ≥ 4.2 |
| 2 | `~/.local/bin` on PATH |
| 3 | `starship`, `fzf`, `zoxide` binaries exist and are functional |
| 4 | ble.sh installed + `.blerc` has fzf integration |
| 5 | `bash-completion` available |
| 6 | Manifest exists, is readable, and `REPO=` matches the current repo location |
| 7 | Every symlink: exists, is a symlink, not dangling, points into repo |
| 8 | `.bashrc` structure: ble.sh Part 1 first, all module sources present, correct load order, ble-attach last |
| 9 | `.blerc` contains fzf integration blocks |
| 10 | `starship.toml` exists and is well-formed |
| 11 | History file is writable |
| 12 | No `fzf --bash` conflict alongside ble.sh |
| 13 | Optional companion tools used by aliases/functions are available *(advisory)* |

---

## Troubleshooting

### Garbage characters in the prompt (`>0;10;1c`, `2;1R`, …)

ble.sh fell back to single-byte mode due to a missing locale. It can no longer consume CSI terminal sequences, so they leak as literal text.

```/dev/null/fix-locale.sh#L1-4
# Check which locales are installed
locale -a | grep en_US

# If en_US.UTF-8 is missing:
sudo locale-gen en_US.UTF-8 && sudo update-locale LANG=en_US.UTF-8
# open a new terminal
```

### `bleopt: option ‘X’ not found`

A `bleopt` call in `.blerc` references an option that doesn’t exist in the installed version of ble.sh. Check the option name in the [ble.sh wiki](https://github.com/akinomyoga/ble.sh/wiki) and remove or correct the line.

### `setlocale: cannot change locale (en_US.UTF-8)`

Bash itself is trying to use a locale that isn’t installed. Run the locale fix above. The warning comes from bash’s own startup before `.bashrc` runs, so it can’t be suppressed by editing shell config.

### `doctor.sh` warns: "No non-interactive guard found in ~/.bashrc"

This is a best-practice warning, not a failure. Re-running `bash setup.sh --skip-tools` will add the guard automatically. The guard `[[ $- != *i* ]] && return` exits immediately for non-interactive shells (scripts, `scp`, `ssh -c`, etc.), preventing aliases, functions, and PATH changes from leaking into non-interactive contexts.

### fzf not found after install

The install placed fzf in `~/.local/bin` which is added to `PATH` by `exports.sh`. Open a new terminal (or `source ~/.bash/exports.sh`) to pick it up.

### `bashrc: WARNING — module not found:`

A module symlink is dangling or was never created. The shell continues but the affected module's settings (PATH changes, aliases, etc.) are inactive.

```/dev/null/fix.sh#L1-1
bash setup.sh --skip-tools   # re-deploy all dotfile symlinks
```

---

## Recovery reference

| Situation | Command |
|---|---|
| Setup crashed halfway | `bash doctor.sh` then `bash setup.sh --skip-tools` |
| Symlinks are dangling (repo moved) | `bash setup.sh --skip-tools` |
| Want to undo everything | `bash uninstall.sh --restore` |
| Wrong backup restored | `bash uninstall.sh --list-backups` then `--restore=TIMESTAMP` |
| Tools missing after install | Open new terminal; then `bash doctor.sh` |
| `.bashrc` load order broken | `bash doctor.sh` — it shows exact line numbers |
| Accidentally removed `.bashrc` | `bash setup.sh --skip-tools` |

---

## How backups work

Every time `setup.sh` overwrites a file it didn't create (i.e. a real file, not one of its own symlinks), it copies the original to:
```
~/.bash_backup/<YYYYMMDD_HHMMSS>/
```
Multiple runs create multiple timestamped backup directories. They accumulate
indefinitely, so `bash uninstall.sh --prune-backups[=N]` (or `make prune-backups
KEEP=<n>`) trims them to the newest N — 5 by default — and `--delete-backup=TS`
removes a single one. `--list-backups` marks the one your current install came
from. `uninstall.sh --restore` uses the backup directory recorded in the manifest (the one that corresponds to *your* install run), not just the most recent directory.

---

## Load order

The most critical aspect of this setup is the **load order** — each tool
has constraints on when it must run relative to others.

```/dev/null/order.txt#L1-17
~/.bashrc
│
├─ 0. ble.sh  --attach=none     ← MUST be first (observes rest of .bashrc)
│
├─ 1. exports.sh                ← PATH, XDG dirs, FZF_* and zoxide env vars
├─ 2. history.sh                ← HISTSIZE, HISTCONTROL, PROMPT_COMMAND hook
├─ 3. completion.sh             ← bash-completion v2, readline options
├─ 4. init.sh                   ← fzf --bash (readline only) + zoxide init
├─ 5. bindings.sh               ← readline / ble.sh key bindings
├─ 6. functions.sh              ← shell functions
├─ 7. aliases.sh                ← aliases
├─ 8. prompt.sh                 ← starship init bash (installs PROMPT_COMMAND)
├─ 9. help.sh                   ← the `cheatsheet` command (no ordering constraints)
│
└─ 10. ble-attach               ← MUST be last (takes over readline after Starship)
```

### Why this order?

- **ble.sh Part 1 first** — ble.sh needs to observe the entire `.bashrc` loading
  process to correctly intercept `PROMPT_COMMAND` and readline hooks set by other tools.
- **exports.sh before everything** — PATH must include `~/.local/bin` before any
  `command -v` checks run in later modules.
- **completion.sh before fzf** — fzf's tab-completion builds on bash-completion.
- **fzf before zoxide** — `zi` uses fzf; zoxide needs to know fzf is available.
- **Starship last among prompt tools** — it installs its own `PROMPT_COMMAND` hook
  and must not be overwritten by later `eval` calls.
- **ble-attach absolute last** — ble.sh must take over readline only after Starship
  has registered all its hooks.

### How modules are loaded safely

`.bashrc` uses a small `_src` helper instead of bare `source`:

```/dev/null/src-helper.sh#L1-5
_src() {
    [[ -f "$1" ]] && source "$1" \
        || echo "bashrc: WARNING — module not found: $1" \
                "(run: bash ~/bash-customizations/setup.sh --skip-tools)" >&2
}
```

If any module file is missing (dangling symlink, interrupted install), `_src` prints a warning with a fix command and continues, so the shell remains usable rather than aborting. `_src` is `unset` after the last module loads and is not available interactively.

---

## ble.sh + fzf: the keymap split

When both ble.sh and fzf are installed, **do not** use `eval "$(fzf --bash)"`.
Instead, ble.sh's built-in integration modules are used (configured in `.blerc`):

```/dev/null/blerc-snippet.sh#L1-2
ble-import -d integration/fzf-completion    # TAB completion via fzf
ble-import -d integration/fzf-key-bindings  # CTRL-T, CTRL-R, ALT-C
```

`init.sh` detects whether `BLE_VERSION` is set and delegates to `.blerc` automatically.

---

## Module reference

### `exports.sh`
- **EDITOR / VISUAL** — defaults to `nano`; change at the top of `exports.sh` if preferred
- **PATH** — prepends `~/.local/bin`, `~/bin`, `~/.cargo/bin` (only if they exist)
- **XDG** — sets `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`
- **MANPAGER / MANROFFOPT** — coloured man pages via `less --use-color` (bold=red, underline=blue)
- **FZF** — `FZF_DEFAULT_COMMAND` (uses `fd` or `rg` when available), `FZF_DEFAULT_OPTS`
  with Catppuccin Mocha colours, per-binding preview options
- **zoxide** — `_ZO_ECHO=1` (prints matched path before jumping)
- **Starship** — `STARSHIP_CONFIG` pointing to `~/.config/starship.toml`

### `history.sh`
- `HISTSIZE=100000` / `HISTFILESIZE=200000`
- `HISTCONTROL=ignoredups:erasedups` — no duplicates, ever
- `HISTTIMEFORMAT` — timestamps on every entry
- `shopt -s histappend cmdhist histreedit`
- `PROMPT_COMMAND` — `history -a; history -c; history -r` after every command
  (immediate save + sync across all open terminals)

### `completion.sh`
- Auto-detects system bash-completion on Linux and Homebrew macOS
- Readline options: `completion-ignore-case` (case-insensitive), `completion-map-case` (hyphens ↔ underscores), `show-all-if-ambiguous`, `colored-stats`, `colored-completion-prefix`, `visible-stats`, `mark-directories`, `mark-symlinked-directories`

### `init.sh`
- **fzf** — `eval "$(fzf --bash)"` only when ble.sh is *not* running
- **zoxide** — `eval "$(zoxide init bash)"` (always)

### `bindings.sh`
- `↑` / `↓` — `history-search-backward/forward` (prefix-aware)
- `CTRL-P` / `CTRL-N` — same
- `ALT-←` / `ALT-→` — word movement
- `CTRL-X CTRL-E` — edit command line in `$EDITOR`
- `skip-completed-text` — avoids re-inserting the already-typed suffix when completing mid-word
- `show-all-if-unmodified` — lists alternatives on the first TAB when the prefix can't be extended

### `functions.sh`

Generated from the `# name — description` comments in [`bash/functions.sh`](bash/functions.sh) — run `make docs` after editing them.

<!-- BEGIN GENERATED: functions -->

#### Navigation

| Function | Description |
|---|---|
| `mkcd <dir>` | make a directory and cd into it in one step |
| `up [n]` | go up n levels in the directory tree (default: 1) |

#### File operations

| Function | Description |
|---|---|
| `extract <archive>` | auto-detect archive format and unpack it |
| `backup-file <file>` | create a dated backup copy of a file |

#### Process / system

| Function | Description |
|---|---|
| `port <number>` | show what process is listening on a given port |
| `ports` | list every listening port and the process behind it |

#### Text / search

| Function | Description |
|---|---|
| `grep-in <pattern> [path]` | recursive grep with a cleaner interface |

#### fzf helpers

| Function | Description |
|---|---|
| `fcd [dir]` | fuzzy cd: interactively pick a directory with fzf *(requires `fzf`)* |
| `fkill [-s SIGNAL] [filter]` | interactively pick a process and kill it *(requires `fzf`)* |

#### Network

| Function | Description |
|---|---|
| `myip` | show public and local IP addresses *(requires `curl`)* |

#### Development

| Function | Description |
|---|---|
| `serve [port]` | start a simple HTTP server in the current directory *(requires `python3`)* |

#### Miscellaneous

| Function | Description |
|---|---|
| `reload` | re-source ~/.bashrc without starting a new shell |
| `tree-all [path]` | tree with hidden files, colours, and pager *(requires `tree`)* |
| `weather [location]` | quick weather report for a location *(requires `curl`)* |
<!-- END GENERATED: functions -->

### `aliases.sh`

Generated from the ` #: ` descriptions in [`bash/aliases.sh`](bash/aliases.sh) — run `make docs` after editing them. Run `cheatsheet` in your shell for the same list, filtered to what is actually installed.

<!-- BEGIN GENERATED: aliases -->

#### Safety rails

| Alias | Expands to | Description |
|---|---|---|
| `cp` | `cp -iv` | copy, asking first and saying what it did |
| `mv` | `mv -iv` | move, asking first and saying what it did |
| `rm` | `rm -iv` | delete, asking about each file |
| `mkdir` | `mkdir -pv` | make a directory, parents included |

#### Directory listing

| Alias | Expands to | Description |
|---|---|---|
| `ls` | `eza --group-directories-first --icons=auto --color=auto` | list files, directories first |
| `ll` | `eza -lah --group-directories-first --icons=auto --git` | long listing with sizes, dates and git state |
| `la` | `eza -a   --group-directories-first --icons=auto` | list everything, dotfiles included |
| `l` | `eza --icons=auto --color=auto` | compact listing |
| `lt` | `eza --tree --level=2 --icons=auto` | tree view, two levels deep *(requires `eza`)* |
| `llt` | `eza --tree --level=3 -lah --icons=auto --git` | tree view, three levels deep, long form *(requires `eza`)* |

#### Navigation

| Alias | Expands to | Description |
|---|---|---|
| `..` | `cd ..` | go up one directory |
| `...` | `cd ../..` | go up two directories |
| `....` | `cd ../../..` | go up three directories |
| `~` | `cd ~` | go to your home directory |
| `-` | `cd -` | go back to the previous directory |

#### Grep

| Alias | Expands to | Description |
|---|---|---|
| `grep` | `grep --color=auto` | grep with matches highlighted |
| `fgrep` | `fgrep --color=auto` | grep for a literal string, highlighted |
| `egrep` | `egrep --color=auto` | grep with extended regexes, highlighted |

#### Disk usage

| Alias | Expands to | Description |
|---|---|---|
| `df` | `df -h` | free space per filesystem, in readable units |
| `du` | `du -h` | disk usage, in readable units |
| `du-dirs` | `du -d1 -h` | size of each subdirectory below here |
| `du-files` | `du -sh *` | size of each entry in this directory |

#### Processes

| Alias | Expands to | Description |
|---|---|---|
| `psa` | `ps auxf` | every process, as a tree |
| `psg` | `ps aux \| grep -v grep \| grep -i` | search the process list, e.g. psg nginx |

#### Network

| Alias | Expands to | Description |
|---|---|---|
| `ping` | `ping -c 5` | ping, stopping after five packets |

#### Editor

| Alias | Expands to | Description |
|---|---|---|
| `v` | `${EDITOR:-nano}` | open a file in $EDITOR |

#### Git

| Alias | Expands to | Description |
|---|---|---|
| `g` | `git` | git |
| `gs` | `git status -sb` | short status with branch and ahead/behind |
| `ga` | `git add` | stage a file |
| `gaa` | `git add --all` | stage every change |
| `gc` | `git commit` | commit staged changes |
| `gcm` | `git commit -m` | commit with a message |
| `gco` | `git checkout` | switch branch or restore a file |
| `gd` | `git diff` | what has changed but is not staged |
| `gds` | `git diff --staged` | what is staged for the next commit |
| `gl` | `git log --oneline --graph --decorate --all` | one-line commit graph of every branch |
| `gp` | `git push` | push to the remote |
| `gpl` | `git pull` | pull from the remote |
| `gb` | `git branch` | list local branches |
| `gba` | `git branch -a` | list local and remote branches |
| `gst` | `git stash` | stash your uncommitted changes |
| `gstp` | `git stash pop` | reapply the most recent stash |

#### Docker

| Alias | Expands to | Description |
|---|---|---|
| `dk` | `docker` | docker *(requires `docker`)* |
| `dkps` | `docker ps` | running containers *(requires `docker`)* |
| `dkpsa` | `docker ps -a` | every container, stopped ones included *(requires `docker`)* |
| `dki` | `docker images` | images on this machine *(requires `docker`)* |
| `dkrm` | `docker rm` | remove a container *(requires `docker`)* |
| `dkrmi` | `docker rmi` | remove an image *(requires `docker`)* |
| `dkx` | `docker exec -it` | run a command in a running container *(requires `docker`)* |
| `dkl` | `docker logs -f` | follow a container's logs *(requires `docker`)* |
| `dkc` | `docker compose` | docker compose *(requires `docker`)* |
| `dkcu` | `docker compose up -d` | start the compose stack detached *(requires `docker`)* |
| `dkcd` | `docker compose down` | stop and remove the compose stack *(requires `docker`)* |

#### System

| Alias | Expands to | Description |
|---|---|---|
| `h` | `history` | your command history |
| `j` | `jobs -l` | background jobs, with their PIDs |
| `path` | `echo -e "${PATH//:/\\n}"` | print each PATH entry on its own line |
| `now` | `date +"%Y-%m-%d %T"` | the current date and time |
| `week` | `date +%V` | the current ISO week number |
| `cls` | `printf "\033c"` | clear the screen and the scrollback buffer |

#### Reload / edit config

| Alias | Expands to | Description |
|---|---|---|
| `bashrc` | `${EDITOR:-nano} ~/.bashrc` | edit ~/.bashrc in $EDITOR |
| `edit-aliases` | `${EDITOR:-nano} ~/.bash/aliases.sh` | edit this file in $EDITOR |
<!-- END GENERATED: aliases -->

### `prompt.sh`
Runs `eval "$(starship init bash)"`. Falls back to a minimal coloured `PS1`
if Starship is not installed.

### `help.sh`
Defines `cheatsheet [filter]`, which prints the two tables above from the live
`~/.bash/` copies — so it works with no repo present, and it marks entries whose
optional tool (`eza`, `docker`) is not installed on this machine.

Sourcing it does no work at all; the files are parsed only when you actually run
`cheatsheet`, so it adds nothing to shell startup.

### `starship.toml`
- **Palette** — Catppuccin Mocha (matches fzf colours in `exports.sh`)
- **Format** — `os › user@host › dir › git_branch+status › lang_modules ··· duration · jobs · time`
- Two-line prompt: info line + `❯` character on its own line
- Languages shown: Python, Node.js, Rust, Go, Java, Docker (only when Dockerfile/docker-compose.yml present)
- `command_timeout = 1000ms` — modules slower than this (e.g. git on NFS mounts) are silently skipped; increase if prompt segments randomly disappear
- `git_state` module shows in-progress operations: REBASE, MERGE, BISECT, CHERRY-PICK

---

## Customisation

### Change the colour scheme
All three tools share the Catppuccin Mocha palette by default. To switch themes:

1. **fzf** — edit `FZF_DEFAULT_OPTS` in `exports.sh` (the `--color=` lines).
2. **Starship** — edit `[palettes.catppuccin_mocha]` in `starship.toml` or swap the `palette =` line for a different named palette.
3. **ble.sh** — uncomment any of the `ble-face` lines in `.blerc` under `Colour / highlighting faces`. Changes take effect immediately after `source ~/.blerc` — no terminal restart needed. The full list of available face names is at: <https://github.com/akinomyoga/ble.sh/wiki/Manual-%C2%A77-Syntax-Highlighting>

### Replace `cd` with zoxide
In `init.sh`, swap the zoxide init line:
```/dev/null/init-snippet.sh#L1-2
# eval "$(zoxide init bash)"         ← default
eval "$(zoxide init bash --cmd cd)"  ← uncomment this
```

### Switch to vi mode
Uncomment `bleopt default_keymap=vi` in `.blerc` (applies to ble.sh) or
`bind "set editing-mode vi"` in `bindings.sh` (plain readline fallback).

### Add your own completions
Drop a completion script in `~/.local/share/bash-completion/completions/`.
bash-completion v2 lazy-loads it automatically.

---

## Adding a new module

To integrate a new module into the managed setup (tracked by setup.sh and doctor.sh):

1. Create `bash/mymodule.sh`
2. Add `_src "$HOME/.bash/mymodule.sh"` to the `_gen_head_block()` function in `setup.sh` at the appropriate load-order position
3. Run `bash setup.sh --skip-tools` — this both deploys the symlink and regenerates the managed block with your new `_src` line
4. Add it to the reference `.bashrc` at the same position — `tests/unit.sh` compares
   the two lists and fails if they disagree
5. Run `bash doctor.sh` to confirm the new module is wired correctly

For a personal addition that doesn't require touching `setup.sh`, skip step 2 and instead add a `source "$HOME/.bash/mymodule.sh"` line directly to `~/.bashrc` **outside** the managed blocks — between `# === END bash-customizations ===` and `# === BEGIN bash-customizations-attach ===`. Then run `bash setup.sh --skip-tools` to deploy the symlink.

---

## Updating tools

`make update` pulls the newest repository release and reinstalls the versions that
release pins. `make update-tools` leaves the checkout unchanged and reinstalls its
current pins. Re-running `bash setup.sh` without `--force` skips tools already on
`PATH`.

Maintainers update the lock in a reviewable step:

```sh
make tools-outdated                         # report available updates
make tools-update                           # update and hash every tool
bash tools/lock-tools.sh --latest fzf       # or update one pin, preserving the rest
git diff -- tools.lock                      # review versions and hashes
make update-tools                           # install exactly those reviewed bytes
```

`make tools-lock` re-downloads the versions already pinned and recomputes every
hash. The lock is replaced only after all platform assets download successfully.
After installing, open a new terminal and run `bash doctor.sh` to verify everything
is consistent.

---

## Testing

The scripts rewrite `~/.bashrc` and deploy symlinks into `$HOME`, so they are
tested where that is safe to do for real: in throwaway containers.

```sh
make lint         # bash -n on every script + shellcheck (skipped if not installed)
make docs-check   # fail if the README tables no longer match bash/*.sh
make test-unit    # module behaviour and argument handling — no container needed
make test-docker  # the full install → doctor → uninstall → restore round trip
make check        # everything CI runs
```

The unit suite also enforces the two rules that keep the docs honest: every alias
carries a ` #: ` description and every function a `— ` one, and the committed README
matches what `make docs` would produce. Adding an undocumented alias fails the build.

`make test-docker` builds three environments from `tests/integration/Dockerfile`
and runs the same suite in each, because the interesting failures are
environmental:

| Environment | What it proves |
|---|---|
| `sudo-user` | The ordinary case: a normal user with passwordless sudo |
| `user-nosudo` | A user with no sudo — optional system packages are skipped, not fatal |
| `root-nosudo` | Root with no `sudo` binary — the container case, where `sudo apt-get` cannot work |

The round trip asserts the things that are hard to notice by hand: that a second
`setup.sh` adds no duplicate blocks, that `--dry-run` changes nothing at all,
that a mistyped `--restore=TIMESTAMP` leaves the install untouched, that an
uninstall with no terminal and no `--yes` exits non-zero, and that a restore
brings `~/.bashrc` back byte-for-byte.

It skips with an explanation when Docker is not running, so `make test` stays
useful without it. CI runs all three environments on every push and pull request
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

---

## Releases

Every release is a git tag (`v1.2.0`), a section in
[`CHANGELOG.md`](CHANGELOG.md), and a
[GitHub Release](https://github.com/devsnb/bash-customizations/releases) whose
body is that section. The `VERSION` file is the single source of truth; the tag
mirrors it, and `setup.sh` records it in the install manifest so a machine can
say which release deployed its dotfiles:

```sh
make version        # this checkout, and what is installed
bash doctor.sh      # warns when the installed version is behind
```

### What the numbers mean here

This is a shell configuration, so the public surface is the names you type and
the flags the scripts accept — not an API:

| Bump | When |
|---|---|
| **major** | An alias or function was renamed or removed, or a script flag changed. Your muscle memory needs updating; read the changelog. |
| **minor** | New aliases, functions, flags or modules. Nothing you already type stops working. |
| **patch** | Fixes, documentation, and internal changes with no user-visible surface. |

Upgrading is safe by design: the managed `~/.bashrc` block is replaced wholesale
rather than patched, `~/.bashrc` is backed up first whenever that block actually
changes, and a module dropped by a release has its symlink pruned instead of
being left dangling.

### Installing a specific release

```sh
git clone https://github.com/devsnb/bash-customizations.git
cd bash-customizations
git checkout v1.0.0
make install
```

### Cutting one

```sh
make release-dry VERSION=1.1.0        # every check, plus the exact diff — writes nothing
make release VERSION=1.1.0            # stamps VERSION, folds Unreleased into a dated
                                      # heading, commits, and annotates the tag
git push --follow-tags origin main    # the only irreversible step
```

`make release` never pushes, and refuses rather than producing a questionable
release — a dirty tree, the wrong branch, an existing tag, an empty `Unreleased`
section, or a failing `make check` all stop it.

**[`docs/RELEASING.md`](docs/RELEASING.md)** is the full guide: what each refusal
means, what CI does with the tag, and how to recover when something goes wrong.

---

## Contributing

1. Fork the repository and create a branch.
2. Edit files in `bash/` or the root scripts.
3. Run `make check` — lint, unit tests, and the container round trip.
4. Add or update inline comments for any behaviour that isn't obvious.
5. Add a line to the `## [Unreleased]` section of [`CHANGELOG.md`](CHANGELOG.md)
   describing the change as a *user* would experience it. Mark anything that
   renames or removes an alias, function or flag as **BREAKING**.
6. Open a pull request — describe what changed and why.

Code style:
- All bash files must pass `bash -n <file>` and `shellcheck --severity=warning`.
- Silencing a shellcheck finding needs an inline `# shellcheck disable=` with a reason;
  only repo-wide false positives belong in `.shellcheckrc`.
- Use `if command -v TOOL &>/dev/null; then` before calling optional tools.
- Guard `&&` chains that could return non-zero with `if`/`fi` (required by `set -e`).
- Document every new alias with a trailing ` #: description` and every new function
  with a `# name [args] — description` comment above it, then run `make docs`. Those
  comments are the single source for `cheatsheet` and the README tables — there is no
  table to edit by hand.
- Aliases must be single-line and must not contain a `#` or a backtick in their
  expansion; the tests enforce both.
- Never edit `VERSION` or the release headings in `CHANGELOG.md` by hand —
  `tools/release.sh` writes both, and the tests fail if they disagree with the
  newest tag.
- Adding or removing a module under `bash/` means updating the reference
  `.bashrc`, `_gen_head_block()` in `setup.sh`, and the fallback lists in
  `doctor.sh` and `uninstall.sh`. A test compares all of them.
