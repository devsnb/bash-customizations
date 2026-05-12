# bash-customizations

A clean, modular Bash setup built around five best-in-class tools.

```/dev/null/tree.txt#L1-14
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
│   └── prompt.sh            ← Starship init + fallback PS1
└── starship.toml            ← Starship config (symlinked → ~/.config/)
```

---

## Repository layout

Files inside `bash/` are symlinked as `~/.bash/`; `.blerc` and `starship.toml` are symlinked directly into `~`. The three root-level scripts stay at the repo root so they can always be run with `bash <script>.sh` from any directory.

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

| Tool | Version | Purpose |
|---|---|---|
| [starship](https://starship.rs) | v1.25.1 | Cross-shell prompt with git, language, and time info |
| [ble.sh](https://github.com/akinomyoga/ble.sh) | nightly | Syntax highlighting, smart completion, auto-suggestions |
| [bash-completion](https://github.com/scop/bash-completion) | v2.17.0 | Tab-completion ecosystem for hundreds of CLI tools |
| [fzf](https://github.com/junegunn/fzf) | v0.62.0 | Fuzzy file finder — CTRL-T, CTRL-R, ALT-C |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | v0.9.9 | Frecency-ranked directory jumper (`z`, `zi`) |

> Versions listed are what `setup.sh` targets. Run `bash doctor.sh` to see what is actually installed on your system.

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
| `git` | fzf install via git | `command -v git` |
| **en_US.UTF-8 locale** | **ble.sh needs it — missing locale causes garbage in prompt** | `locale -a \| grep en_US` |

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
| `make update` | Reinstall / upgrade all tools to latest versions |
| `make dry-run` | Preview what install would do without making changes |
| `make doctor` | Diagnose the setup and show fix instructions |
| `make uninstall` | Remove managed symlinks and blocks from `~/.bashrc` |
| `make restore` | Uninstall and restore the most recent backup |
| `make purge` | Uninstall and remove all tool binaries |
| `make list-backups` | List available backup timestamps |

You can also invoke the scripts directly if you prefer:

### Script flags

| Flag | Effect |
|---|---|
| *(none)* | Install all tools + deploy dotfiles |
| `--dry-run` | Show what would happen, change nothing |
| `--skip-tools` | Deploy dotfiles only (tools already installed) |
| `--force` | Re-install even if a tool is already present |
| `-h`, `--help` | Print usage, examples, and recovery hints, then exit |

To upgrade installed tools to their latest versions, run `make update` or `bash setup.sh --force`. See [Updating tools](#updating-tools) for per-tool commands.

---

## Uninstalling

```sh
make restore                                    # remove symlinks + restore latest backup
make purge                                      # also remove tool binaries

# Or with the script directly:
bash uninstall.sh --dry-run                     # preview what would be removed
bash uninstall.sh --list-backups                # show available timestamps
bash uninstall.sh --restore=20250604_142301     # restore a specific backup
bash uninstall.sh --restore --purge-tools       # full removal including binaries
```

**Safety guarantees of `uninstall.sh`:**
- Removes only the two managed blocks from `~/.bashrc`; all other content is untouched
- Reads the install manifest to know *exactly* which symlinks `setup.sh` created
- Verifies each symlink points back into this repo before touching it
- Falls back to a hardcoded default list if no manifest exists
- Never removes system packages (`bash-completion` stays)
- Always asks for confirmation before `--purge-tools`

---

## Diagnosing a broken setup

```/dev/null/doctor-examples.sh#L1-5
# Full diagnostics
bash doctor.sh

# Failures only (good for CI or scripting)
bash doctor.sh --quiet
echo "Exit: $?"   # 0 = healthy, 1 = issues found
```

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
Multiple runs create multiple timestamped backup directories. `uninstall.sh --restore` uses the backup directory recorded in the manifest (the one that corresponds to *your* install run), not just the most recent directory.

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
│
└─ 9. ble-attach                ← MUST be last (takes over readline after Starship)
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
- **EDITOR / VISUAL** — defaults to `nvim`; change at the top of `exports.sh` if preferred
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

| Function | Description |
|---|---|
| `mkcd <dir>` | `mkdir -p` + `cd` |
| `up [n]` | Go up *n* directory levels |
| `extract <archive>` | Auto-detect and unpack any archive format |
| `bak <file>` | Create a timestamped backup copy |
| `port <n>` | Show what's listening on port *n* |
| `find-in <pat> [path]` | Recursive coloured grep |
| `fcd [dir]` | Fuzzy `cd` using fzf; optional starting directory (default: `.`) |
| `fkill [signal]` | Interactively pick and kill a process; optional signal number (default: `15` / SIGTERM) |
| `myip` | Show public + local IP |
| `serve [port]` | Python HTTP server in current dir |
| `reload` | Re-source `~/.bashrc` in place (may cause prompt glitches when ble.sh is active — prefer opening a new terminal) |
| `tre` | `tree` with hidden files + pager |
| `weather [location]` | wttr.in weather report |

### `aliases.sh`
- **Safety** — `cp/mv/rm` with `-iv`, `mkdir -pv`
- **ls** — prefers `eza` when installed: `ls`, `ll`, `la`, `l` (standard views), `lt` (tree 2 levels), `llt` (tree 3 levels, long form); falls back to `ls --color`
- **cat/less** — prefers `bat` when installed; falls back to standard commands
- **Navigation** — `..` / `...` / `....` (go up 1–3 levels), `~` (go home), `-` (go to previous directory)
- **grep** — `grep`, `fgrep`, `egrep` all with `--color=auto`
- **Disk usage** — `df -h`, `du -h`, `dud` (subdirectory sizes), `duf` (files in current dir)
- **Processes** — `psa` (`ps auxf`), `psg <name>` (grep process list)
- **Network** — `ping -c 5`, `ports` (`ss -tulpn` — list listening ports)
- **Editor** — `v` / `vi` → `$EDITOR` (defaults to `nvim`)
- **git** — `gs`, `gl`, `gd`, `gc`, `gp`, `gpl`, `gco`, `gst`, …
- **docker** — `dk`, `dkps`, `dkpsa`, `dki`, `dkrm`, `dkrmi`, `dkx`, `dkl`, `dkc`, `dkcu`, `dkcd` (only if `docker` is installed)
- **System** — `h` (history), `j` (jobs), `path` (print `$PATH` entries one per line), `now` (current datetime), `week` (ISO week number), `cls` (full terminal reset including scrollback)
- **Config shortcuts** — `bashrc` opens `~/.bashrc` in `$EDITOR`; `aliases` opens `~/.bash/aliases.sh`

### `prompt.sh`
Runs `eval "$(starship init bash)"`. Falls back to a minimal coloured `PS1`
if Starship is not installed.

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
4. Run `bash doctor.sh` to confirm the new module is wired correctly

For a personal addition that doesn't require touching `setup.sh`, skip step 2 and instead add a `source "$HOME/.bash/mymodule.sh"` line directly to `~/.bashrc` **outside** the managed blocks — between `# === END bash-customizations ===` and `# === BEGIN bash-customizations-attach ===`. Then run `bash setup.sh --skip-tools` to deploy the symlink.

---

## Updating tools

Re-running `bash setup.sh` skips tools that are already installed. To upgrade to the latest versions use `--force`:

```/dev/null/update.sh#L1-8
# Upgrade everything
bash setup.sh --force

# Upgrade individual tools manually:
#   starship  — curl -sS https://starship.rs/install.sh | sh
#   fzf       — git -C ~/.fzf pull && ~/.fzf/install --all --no-bash --no-zsh --no-fish
#   zoxide    — curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
#   ble.sh    — bash setup.sh --force  (re-downloads the nightly tarball)
```

After upgrading, open a new terminal and run `bash doctor.sh` to verify everything is consistent.

---

## Contributing

1. Fork the repository and create a branch.
2. Edit files in `bash/` or the root scripts.
3. Test with `bash setup.sh --dry-run` and `bash doctor.sh`.
4. Add or update inline comments for any behaviour that isn't obvious.
5. Open a pull request — describe what changed and why.

Code style:
- All bash files must pass `bash -n <file>` (syntax check).
- Use `if command -v TOOL &>/dev/null; then` before calling optional tools.
- Guard `&&` chains that could return non-zero with `if`/`fi` (required by `set -e`).
- Document new functions with a one-line description in `functions.sh` and a row in the README table.
