#!/usr/bin/env bash
# setup.sh
#
# Idempotent setup script for the bash-customizations dotfile repo.
#
# What it does (in order):
#   1. Checks prerequisites (Bash ≥ 4.2, curl/wget, git)
#   1.5. Ensures en_US.UTF-8 locale is installed (required by ble.sh)
#   2. Installs: starship · ble.sh · bash-completion · fzf · zoxide
#   3. Deploys dotfiles (.bashrc · .bash/ · .blerc · starship.toml)
#      with automatic backup of any existing files/directories
#   4. Verifies that each tool is on PATH and prints a summary
#
# Usage:
#   bash setup.sh              # full install
#   bash setup.sh --dry-run    # show what would happen, change nothing
#   bash setup.sh --skip-tools # deploy dotfiles only (tools already installed)
#
# Re-running is safe — already-installed tools and already-deployed files are
# detected and skipped, unless --force is passed.
#
# Tool versions installed:
#   starship        v1.25.1
#   ble.sh          nightly (0.4.0-devel3+)
#   bash-completion v2.17.0
#   fzf             v0.62.0  (latest via git)
#   zoxide          v0.9.9
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Catch unexpected exits and warn the user rather than leaving silent breakage.
trap '_on_error $? $LINENO' ERR
_on_error() {
    echo -e "\n${RED:-}[ERROR]${RESET:-} setup.sh failed (exit $1 at line $2)." >&2
    echo    "        If dotfiles were partially deployed, run:" >&2
    echo    "          bash uninstall.sh --restore   # restore previous state" >&2
    echo    "          bash doctor.sh               # diagnose what's broken" >&2
}

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${HOME}/.bash_backup/$(date +%Y%m%d_%H%M%S)"
BASH_DIR="${HOME}/.bash"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
LOCAL_BIN="${HOME}/.local/bin"

# Manifest — records every symlink we create so uninstall.sh knows exactly
# what to clean up.  One file, human-readable key=value format.
MANIFEST_DIR="${HOME}/.local/share/bash-customizations"
MANIFEST_FILE="${MANIFEST_DIR}/manifest"

# Block markers injected into ~/.bashrc (setup never symlinks ~/.bashrc)
BLOCK_HEAD_BEGIN="# === BEGIN bash-customizations ==="
BLOCK_HEAD_END="# === END bash-customizations ==="
BLOCK_TAIL_BEGIN="# === BEGIN bash-customizations-attach ==="
BLOCK_TAIL_END="# === END bash-customizations-attach ==="

# Runtime tracking (populated by deploy_file / _ensure_noninteractive_guard)
DEPLOYED_LINKS=()
BACKUP_CREATED=false
GUARD_ADDED=false

# Flags (set by CLI args below)
DRY_RUN=false
SKIP_TOOLS=false
FORCE=false

# ══════════════════════════════════════════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════════════════════════════════════════

# Palette, glyphs, log_* and has() are shared with doctor.sh and uninstall.sh.
if [[ ! -f "${REPO_DIR}/lib/log.sh" ]]; then
    echo "setup.sh: cannot find ${REPO_DIR}/lib/log.sh" >&2
    echo "          The repository looks incomplete — re-clone it and try again." >&2
    exit 1
fi
# shellcheck source=lib/log.sh
source "${REPO_DIR}/lib/log.sh"

# run CMD [args…] — execute or just print in dry-run mode.
run() {
    if $DRY_RUN; then
        log_dry "$*"
    else
        "$@"
    fi
}

# _as_root CMD [args…] — run a command with root privileges, if we can.
#
# Bare `sudo` is wrong in two common cases: inside a container the user is
# already root and sudo often is not installed at all, and on a locked-down box
# there is no sudo access to be had.  Under `set -euo pipefail` either one used
# to abort the whole install partway through.  Returns non-zero (without
# running anything) when privileges are unavailable, so callers can decide
# whether the step was essential.
_as_root() {
    if $DRY_RUN; then
        log_dry "$([[ $EUID -eq 0 ]] || echo 'sudo ')$*"
        return 0
    fi
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif has sudo; then
        sudo "$@"
    else
        log_warn "Root privileges needed but 'sudo' is not available: $*"
        return 1
    fi
}

# root_available — true if a privileged command could be run at all.
root_available() { [[ $EUID -eq 0 ]] || has sudo; }

# ver CMD — print version string (best-effort).
ver() {
    "$1" --version 2>/dev/null | head -1 || true
}

# replace_file TMP DEST — move a rewritten temp file into place, keeping DEST's
# original permissions.  mktemp creates 0600 files and mv carries that mode
# across, which would silently tighten ~/.bashrc on every run.
replace_file() {
    local tmp="$1" dest="$2"
    local mode=""
    if [[ -f "$dest" ]]; then
        mode="$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest" 2>/dev/null || true)"
    fi
    mv "$tmp" "$dest"
    [[ -n "$mode" ]] && chmod "$mode" "$dest"
    return 0
}

# backup TARGET — copy TARGET to BACKUP_DIR if it exists and is not a symlink
# pointing into the repo (i.e. already managed by us).
backup_if_exists() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    # If it's a symlink pointing into our repo, skip.
    if [[ -L "$target" ]]; then
        local link_dest
        link_dest="$(readlink -f "$target" 2>/dev/null \
                  || readlink "$target" 2>/dev/null || true)"
        [[ "$link_dest" == "${REPO_DIR}/"* ]] && return 0
    fi
    # Preserve directory structure relative to $HOME so restore_backup can
    # reconstruct the original path.  e.g. ~/.config/starship.toml is backed
    # up as $BACKUP_DIR/.config/starship.toml, not flat as $BACKUP_DIR/starship.toml.
    local rel_path="${target#"${HOME}/"}"
    if $DRY_RUN; then
        log_dry "Back up $target ${GLYPH_ARROW} $BACKUP_DIR/${rel_path}"
    else
        log_info "Backing up $target ${GLYPH_ARROW} $BACKUP_DIR/${rel_path}"
    fi
    run mkdir -p "${BACKUP_DIR}/$(dirname "$rel_path")"
    run cp -a "$target" "${BACKUP_DIR}/${rel_path}"
    BACKUP_CREATED=true
}

# deploy_file SRC DEST — symlink DEST → SRC (or copy in dry-run).
# Creates parent directories as needed.
deploy_file() {
    local src="$1" dest="$2"

    if [[ ! -f "$src" ]]; then
        log_warn "Source not found, skipping: $src"
        return 0
    fi

    # Already correctly linked?
    if [[ -L "$dest" ]]; then
        local current_target src_real
        current_target="$(readlink -f "$dest" 2>/dev/null \
                       || readlink "$dest" 2>/dev/null || true)"
        src_real="$(readlink -f "$src" 2>/dev/null \
                 || readlink "$src" 2>/dev/null || echo "$src")"
        if [[ "$current_target" == "$src_real" ]]; then
            log_ok "Already linked: $dest"
            # Record it even on a no-op run so the manifest stays complete.
            # Without this, re-running --skip-tools writes an empty LINK list.
            DEPLOYED_LINKS+=("$dest")
            return 0
        fi
    fi

    backup_if_exists "$dest"
    run mkdir -p "$(dirname "$dest")"

    if $DRY_RUN; then
        log_dry "ln -sf $src $dest"
    else
        ln -sf "$src" "$dest"
        DEPLOYED_LINKS+=("$dest")
        log_ok "Linked: $dest ${GLYPH_ARROW} $src"
    fi
}

# deploy_dir SRC_DIR DEST_DIR — symlink each *.sh file inside SRC_DIR into DEST_DIR.
# Non-.sh files in the source dir (READMEs, etc.) are intentionally skipped.
deploy_dir() {
    local src_dir="$1" dest_dir="$2"
    run mkdir -p "$dest_dir"
    for src_file in "$src_dir"/*.sh; do
        [[ -f "$src_file" ]] || continue
        deploy_file "$src_file" "${dest_dir}/$(basename "$src_file")"
    done
    prune_orphaned_links "$dest_dir"
}

# prune_orphaned_links DEST_DIR — drop links we own whose source no longer exists.
#
# A release that deletes bash/foo.sh would otherwise strand ~/.bash/foo.sh as a
# dangling symlink: it disappears from the rewritten manifest, so neither
# uninstall.sh nor doctor.sh can see it any more, and it survives even a full
# uninstall.  Only links resolving into this repo are touched — whatever else a
# user has put in ~/.bash is theirs.
prune_orphaned_links() {
    local dest_dir="$1" link target
    for link in "$dest_dir"/*.sh; do
        [[ -L "$link" ]] || continue
        target="$(readlink "$link" 2>/dev/null || true)"
        # Not ours: leave it strictly alone.
        if [[ "$target" != "${REPO_DIR}/"* ]]; then continue; fi
        # Source still present: nothing to do.
        if [[ -f "$target" ]]; then continue; fi
        if $DRY_RUN; then
            log_dry "Would remove orphaned link (source no longer in the repo): $link"
        else
            rm -f "$link"
            log_ok "Removed orphaned link (source no longer in the repo): $link"
        fi
    done
}

# download URL — print the raw content of a URL using curl or wget.
#
# Progress goes to stderr so the payload on stdout stays clean for the callers
# that pipe it into tar or sh.  Without it the multi-megabyte ble.sh fetch looks
# exactly like a hang.  The connect timeout turns an unreachable host into a
# quick, clear failure instead of a two-minute stall.
# Pass -q for small metadata requests where a progress bar is just noise.
download() {
    local quiet=false
    if [[ "${1:-}" == "-q" ]]; then quiet=true; shift; fi

    if has curl; then
        if $quiet; then curl -fsSL --connect-timeout 15 "$1"
        else            curl -fL   --connect-timeout 15 --progress-bar "$1"; fi
    elif has wget; then
        if $quiet; then wget --connect-timeout=15 -qO- "$1"
        else            wget --connect-timeout=15 --show-progress -qO- "$1"; fi
    else
        log_error "Neither curl nor wget found — cannot download."
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Parse CLI arguments
# ══════════════════════════════════════════════════════════════════════════════

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)    DRY_RUN=true    ;;
            --skip-tools) SKIP_TOOLS=true ;;
            --force)      FORCE=true      ;;
            -h|--help)
                echo "Usage: bash setup.sh [--dry-run] [--skip-tools] [--force]"
                echo
                echo "  --dry-run     Show what would happen without making changes"
                echo "  --skip-tools  Deploy dotfiles only, skip tool installation"
                echo "  --force       Overwrite existing installations"
                echo
                echo "Examples:"
                echo "  bash setup.sh                        # first-time full install"
                echo "  bash setup.sh --dry-run              # preview without changing anything"
                echo "  bash setup.sh --skip-tools           # re-deploy dotfiles only"
                echo "  bash setup.sh --force                # reinstall even if already installed"
                echo
                echo "Recovery:"
                echo "  bash uninstall.sh --restore    Restore the most recent backup"
                echo "  bash doctor.sh                 Diagnose a broken setup"
                exit 0
                ;;
            *)
                log_error "Unknown argument: $arg (use --help for usage)"
                exit 1
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Prerequisites
# ══════════════════════════════════════════════════════════════════════════════

check_prerequisites() {
    log_section "Checking prerequisites"

    # Bash version ≥ 4.2
    local bash_major="${BASH_VERSINFO[0]}" bash_minor="${BASH_VERSINFO[1]}"
    if (( bash_major < 4 || ( bash_major == 4 && bash_minor < 2 ) )); then
        log_error "Bash 4.2+ required (found ${BASH_VERSION})."
        log_error "On macOS, install a newer Bash: brew install bash"
        exit 1
    fi
    log_ok "Bash ${BASH_VERSION}"

    # curl or wget
    if ! has curl && ! has wget; then
        log_error "curl or wget is required for downloading tools."
        exit 1
    fi
    if has curl; then log_ok "curl $(curl --version 2>/dev/null | head -1)"; fi
    if has wget; then log_ok "wget $(wget --version 2>/dev/null | head -1)"; fi

    # git (needed for fzf install via git)
    if ! has git; then
        log_warn "git not found — fzf will be installed via package manager if possible."
    else
        log_ok "git $(git --version)"
    fi

    # tar + xz — ble.sh ships as a .tar.xz and is unpacked with `tar -xJf`.
    # Without these the failure surfaces late and cryptically, mid-download.
    if ! has tar; then
        log_error "tar is required to unpack ble.sh."
        exit 1
    fi
    log_ok "tar $(tar --version 2>/dev/null | head -1)"
    if ! has xz; then
        log_warn "xz not found — ble.sh (.tar.xz) cannot be unpacked."
        log_warn "  Debian/Ubuntu: sudo apt-get install -y xz-utils"
    fi

    # Say up front that some steps need root, rather than surprising the user
    # with a password prompt halfway through the run.
    if ! $SKIP_TOOLS; then
        if [[ $EUID -eq 0 ]]; then
            log_info "Running as root — package installs will not use sudo."
        elif has sudo; then
            log_info "Some optional steps (bash-completion, locale) may ask for your sudo password."
        else
            log_warn "No sudo available — package installs and locale generation will be skipped."
            log_warn "Everything installed into ~/.local/bin works without root."
        fi
    fi

    # make is not required by this setup (ble.sh installs from a pre-built tarball).
    if has make; then log_ok "make $(make --version 2>/dev/null | head -1)"; fi

    # Ensure ~/.local/bin exists and takes precedence on PATH. This matters
    # when a distro package ships an older binary than the one we install.
    run mkdir -p "$LOCAL_BIN"
    if [[ ":${PATH}:" != *":${LOCAL_BIN}:"* ]]; then
        log_warn "$LOCAL_BIN is not on PATH yet. It will be added by exports.sh after setup."
        export PATH="${LOCAL_BIN}:${PATH}"
    elif [[ "$PATH" != "$LOCAL_BIN" && "$PATH" != "${LOCAL_BIN}:"* ]]; then
        log_info "Prepending $LOCAL_BIN to PATH so managed tools take precedence."
        export PATH="${LOCAL_BIN}:${PATH}"
    fi

    # Said here rather than only in the closing summary: the prompt renders its
    # icons as tofu without a Nerd Font, and installing one afterwards means
    # looking at a broken prompt in between.
    log_info "The Starship prompt needs a Nerd Font to draw its icons."
    log_info "  Download one now if you have not: https://www.nerdfonts.com/font-downloads"
    log_info "  then set it as your terminal's font."
}

# ══════════════════════════════════════════════════════════════════════════════
# Tool installers
# ══════════════════════════════════════════════════════════════════════════════

# ── Starship ──────────────────────────────────────────────────────────────────
install_starship() {
    log_section "Starship (v1.25.1+)"

    if has starship && ! $FORCE; then
        log_ok "Starship already installed: $(ver starship)"
        return 0
    fi

    log_info "Installing Starship to ${LOCAL_BIN}…"
    if $DRY_RUN; then
        log_dry "curl -sS https://starship.rs/install.sh | sh -s -- --bin-dir ${LOCAL_BIN} --yes"
    else
        download https://starship.rs/install.sh \
            | sh -s -- --bin-dir "${LOCAL_BIN}" --yes
    fi
    if has starship; then log_ok "Starship installed: $(ver starship)"; fi
}

# ── ble.sh ────────────────────────────────────────────────────────────────────
install_blesh() {
    log_section "ble.sh (nightly)"

    local blesh_dir="${XDG_DATA_HOME}/blesh"

    if [[ -f "${blesh_dir}/ble.sh" ]] && ! $FORCE; then
        log_ok "ble.sh already installed at ${blesh_dir}"
        return 0
    fi

    log_info "Installing ble.sh nightly to ${blesh_dir}…"
    if $DRY_RUN; then
        log_dry "curl -L https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz | tar xJf - -C /tmp && bash /tmp/ble-nightly/ble.sh --install ${XDG_DATA_HOME}"
        return 0
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # Inline cleanup: explicitly remove on success AND on failure.
    # We don't use a RETURN trap because bash's set -e bypasses RETURN traps
    # (it triggers an ERR trap then exits the script entirely, not a return).
    local blesh_ok=false
    if download "https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz" \
            | tar -xJf - -C "$tmp_dir" \
        && bash "${tmp_dir}/ble-nightly/ble.sh" --install "${XDG_DATA_HOME}"; then
        blesh_ok=true
    fi
    rm -rf "$tmp_dir"
    if $blesh_ok; then
        log_ok "ble.sh installed at ${blesh_dir}"
    else
        log_error "ble.sh installation failed (download or install step returned non-zero)"
        return 1
    fi
}

# ── bash-completion ───────────────────────────────────────────────────────────
install_bash_completion() {
    log_section "bash-completion (v2.17.0+)"

    # Already loaded by the system?
    if [[ -n "${BASH_COMPLETION_VERSINFO:-}" ]] && ! $FORCE; then
        log_ok "bash-completion already active (v${BASH_COMPLETION_VERSINFO[0]}.${BASH_COMPLETION_VERSINFO[1]})"
        return 0
    fi

    # Already installed on disk?
    if [[ -f /usr/share/bash-completion/bash_completion ]] && ! $FORCE; then
        log_ok "bash-completion package already installed (system-wide)"
        return 0
    fi

    # bash-completion is the one dependency that lives in system paths, so it is
    # also the one that needs root.  It is a nice-to-have, not a prerequisite:
    # a failure here must never take the rest of the install down with it.
    if ! has brew && ! root_available; then
        log_warn "Skipping bash-completion — needs root and no sudo is available."
        log_warn "Install it yourself later: <your package manager> install bash-completion"
        return 0
    fi

    log_info "Installing bash-completion via system package manager…"

    if $DRY_RUN; then
        if has apt-get;  then  log_dry "apt-get update && apt-get install -y bash-completion"
        elif has dnf;    then  log_dry "dnf install -y bash-completion"
        elif has pacman; then  log_dry "pacman -S --noconfirm bash-completion"
        elif has brew;   then  log_dry "brew install bash-completion@2"
        else                   log_dry "<package manager> install bash-completion"
        fi
        return 0
    fi

    local installed=false
    if has apt-get; then
        # A container image's package lists are usually stale; without an update
        # the install fails with "Unable to locate package".
        _as_root apt-get update -qq \
            && _as_root apt-get install -y bash-completion && installed=true
    elif has dnf; then
        _as_root dnf install -y bash-completion && installed=true
    elif has pacman; then
        _as_root pacman -S --noconfirm bash-completion && installed=true
    elif has zypper; then
        _as_root zypper install -y bash-completion && installed=true
    elif has brew; then
        brew install bash-completion@2 && installed=true
    else
        log_warn "No supported package manager found."
        log_warn "Please install bash-completion manually: https://github.com/scop/bash-completion"
        return 0
    fi

    if $installed; then
        log_ok "bash-completion installed."
    else
        log_warn "bash-completion could not be installed — continuing without it."
        log_warn "Tab-completion for third-party tools will be limited."
    fi
    return 0
}

# ── fzf ───────────────────────────────────────────────────────────────────────
install_fzf() {
    log_section "fzf (v0.62.0+)"

    if has fzf && ! $FORCE; then
        log_ok "fzf already installed: $(ver fzf)"
        return 0
    fi

    log_info "Installing fzf…"

    if $DRY_RUN; then
        if [[ -d "${HOME}/.fzf" ]]; then
            log_dry "git -C ~/.fzf pull --ff-only"
        else
            log_dry "git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf"
        fi
        log_dry "~/.fzf/install --all --no-bash --no-zsh --no-fish"
        log_dry "ln -sf ~/.fzf/bin/fzf ${LOCAL_BIN}/fzf"
        return 0
    fi

    if has git; then
        # Git method — clones the tip of the default branch (tracks latest closely).
        if [[ -d "${HOME}/.fzf" ]]; then
            log_info "Updating existing fzf clone…"
            git -C "${HOME}/.fzf" pull --ff-only
        else
            git clone --depth 1 https://github.com/junegunn/fzf.git "${HOME}/.fzf"
        fi
        # --no-bash / --no-zsh / --no-fish  — don't let fzf touch shell configs;
        # we manage that ourselves via init.sh.
        "${HOME}/.fzf/install" --all --no-bash --no-zsh --no-fish
        # The git installer puts the binary in ~/.fzf/bin — symlink it into
        # ~/.local/bin so it's on the PATH we manage in exports.sh.
        if [[ -f "${HOME}/.fzf/bin/fzf" ]]; then
            ln -sf "${HOME}/.fzf/bin/fzf" "${LOCAL_BIN}/fzf"
            # Deliberately NOT added to DEPLOYED_LINKS: the manifest means
            # "symlinks into this repo", and both uninstall.sh and doctor.sh
            # treat anything else as suspicious.  This link belongs to the fzf
            # install and is cleaned up by --purge-tools instead.
            log_ok "Linked ~/.fzf/bin/fzf ${GLYPH_ARROW} ${LOCAL_BIN}/fzf"
        fi
    elif has apt-get && root_available; then
        _as_root apt-get update -qq && _as_root apt-get install -y fzf
    elif has dnf && root_available; then
        _as_root dnf install -y fzf
    elif has pacman && root_available; then
        _as_root pacman -S --noconfirm fzf
    elif has brew; then
        brew install fzf
    else
        # Last resort: download pre-built binary from GitHub releases.
        # The asset filename includes the version, so we query the API first.
        log_info "Downloading fzf binary from GitHub releases…"
        local arch os_name fzf_ver fzf_url
        arch="$(uname -m)"
        os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
        case "$arch" in
            x86_64)          arch="amd64"  ;;
            aarch64|arm64)   arch="arm64"  ;;
            armv7l|armv6l)   arch="armv7"  ;;
            i386|i686)       arch="386"    ;;
            *)
                log_error "fzf: unsupported architecture '${arch}' for binary download"
                log_error "Install manually: https://github.com/junegunn/fzf/releases"
                return 1
                ;;
        esac
        fzf_ver="$(download -q "https://api.github.com/repos/junegunn/fzf/releases/latest" \
                   | grep '"tag_name"' \
                   | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" || fzf_ver=""
        if [[ -z "$fzf_ver" ]]; then
            log_error "Could not determine latest fzf version from GitHub API"
            return 1
        fi
        fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_ver}/fzf-${fzf_ver}-${os_name}_${arch}.tar.gz"
        log_info "Fetching fzf v${fzf_ver} for ${os_name}/${arch}…"
        mkdir -p "$LOCAL_BIN"
        download "$fzf_url" | tar -xzf - -C "$LOCAL_BIN" fzf
        chmod +x "${LOCAL_BIN}/fzf"
    fi
    if has fzf; then log_ok "fzf installed: $(ver fzf)"; fi
}

# ── zoxide ────────────────────────────────────────────────────────────────────
install_zoxide() {
    log_section "zoxide (v0.9.9+)"

    if has zoxide && ! $FORCE; then
        log_ok "zoxide already installed: $(ver zoxide)"
        return 0
    fi

    log_info "Installing zoxide to ${LOCAL_BIN}…"
    if $DRY_RUN; then
        log_dry "curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh"
        return 0
    fi

    download "https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh" \
        | env INSTALL_PREFIX="${LOCAL_BIN}" sh
    if has zoxide; then log_ok "zoxide installed: $(ver zoxide)"; fi
}

# ══════════════════════════════════════════════════════════════════════════════
# .bashrc block injection
# ══════════════════════════════════════════════════════════════════════════════

# _gen_head_block — print the full HEAD block (markers + content) to stdout.
_gen_head_block() {
    echo "$BLOCK_HEAD_BEGIN"
    # Embed the actual repo path so the warning message is always accurate.
    printf '_bc_repo="%s"\n' "$REPO_DIR"
    cat <<'CONTENT'
# Managed by setup.sh — do not edit this block. Re-run: bash "$_bc_repo/setup.sh"

# ble.sh Part 1 — must be before all other setup
_blesh="${XDG_DATA_HOME:-$HOME/.local/share}/blesh/ble.sh"
if [[ -f "$_blesh" ]]; then
    # shellcheck source=/dev/null
    source -- "$_blesh" --attach=none
fi
unset _blesh

# Source helper — warns if a module is missing rather than aborting
_src() {
    if [[ -f "$1" ]]; then
        # shellcheck source=/dev/null
        source "$1"
    else
        echo "bashrc: WARNING — module not found: $1" \
             "(run: bash $_bc_repo/setup.sh --skip-tools)" >&2
    fi
}

_src "$HOME/.bash/exports.sh"
_src "$HOME/.bash/history.sh"
_src "$HOME/.bash/completion.sh"
_src "$HOME/.bash/init.sh"
_src "$HOME/.bash/bindings.sh"
_src "$HOME/.bash/functions.sh"
_src "$HOME/.bash/aliases.sh"
_src "$HOME/.bash/prompt.sh"
_src "$HOME/.bash/help.sh"

unset -f _src
unset _bc_repo
CONTENT
    echo "$BLOCK_HEAD_END"
}

# _gen_tail_block — print the full TAIL block (markers + content) to stdout.
_gen_tail_block() {
    echo "$BLOCK_TAIL_BEGIN"
    cat <<'CONTENT'
# Managed by setup.sh — do not edit this block. Re-run: bash setup.sh
# ble-attach must be the last interactive statement in .bashrc.
[[ ${BLE_VERSION:-} ]] && ble-attach
CONTENT
    echo "$BLOCK_TAIL_END"
}

# _backup_before_upgrade FILE — snapshot FILE before rewriting its managed block.
#
# Deliberately NOT backup_if_exists: that marks BACKUP_CREATED, which makes
# write_manifest point BACKUP= at this run's directory.  The manifest's BACKUP=
# is what --restore resolves to, and it must keep pointing at the pre-install
# snapshot — the one that returns the user to the state they had before any of
# this existed.  An upgrade snapshot is a different thing and gets its own
# directory, mirroring uninstall.sh's -pre-restore convention.
_backup_before_upgrade() {
    local file="$1" dir
    dir="${HOME}/.bash_backup/$(date +%Y%m%d_%H%M%S)-pre-upgrade"
    if $DRY_RUN; then
        log_dry "Back up $file ${GLYPH_ARROW} ${dir}/.bashrc  (managed block changed)"
        return 0
    fi
    log_info "The managed block differs from this version — saving ${file} to ${dir} first."
    mkdir -p "$dir"
    cp -a "$file" "${dir}/.bashrc"
}

# _extract_block FILE BEGIN END — print one managed block, markers included.
_extract_block() {
    awk -v b="$2" -v e="$3" '
        $0 == b { inb = 1 }
        inb     { print }
        $0 == e { inb = 0 }
    ' "$1" 2>/dev/null || true
}

# _blocks_are_current FILE — true when FILE's managed blocks are byte-identical
# to what this version of setup.sh would write.  Used to decide whether an
# upgrade needs a fresh backup before rewriting them.
_blocks_are_current() {
    local file="$1" current expected
    current="$(_extract_block "$file" "$BLOCK_HEAD_BEGIN" "$BLOCK_HEAD_END"
               _extract_block "$file" "$BLOCK_TAIL_BEGIN" "$BLOCK_TAIL_END")"
    expected="$(_gen_head_block
                _gen_tail_block)"
    [[ "$current" == "$expected" ]]
}

# _rewrite_block FILE BEGIN END NEW_BLOCK_FILE
# Replace the old block (between BEGIN and END inclusive) with NEW_BLOCK_FILE.
# NEW_BLOCK_FILE must include the begin/end marker lines.
_rewrite_block() {
    local file="$1" begin="$2" end="$3" new_block_file="$4"
    local tmp
    tmp="$(mktemp)"
    local in_block=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$begin" ]]; then
            cat "$new_block_file"
            in_block=1
        elif [[ $in_block -eq 1 && "$line" == "$end" ]]; then
            in_block=0
        elif [[ $in_block -eq 0 ]]; then
            echo "$line"
        fi
    done < "$file" > "$tmp"
    replace_file "$tmp" "$file"
}

# _inject_blocks FILE HEAD_FILE TAIL_FILE
# Insert HEAD block after the non-interactive guard (or prepend if absent),
# then append TAIL block at the end of FILE.
_inject_blocks() {
    local file="$1" head_file="$2" tail_file="$3"
    local tmp
    tmp="$(mktemp)"
    local inserted_head=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        echo "$line"
        if [[ $inserted_head -eq 0 && "$line" == *'$-'*'*i*'*'return'* ]]; then
            echo ""
            cat "$head_file"
            echo ""
            inserted_head=1
        fi
    done < "$file" > "$tmp"

    if [[ $inserted_head -eq 0 ]]; then
        # No non-interactive guard found — prepend HEAD block
        local tmp2
        tmp2="$(mktemp)"
        { cat "$head_file"; echo ""; cat "$tmp"; } > "$tmp2"
        mv "$tmp2" "$tmp"
    fi

    # Append TAIL block
    { cat "$tmp"; echo ""; cat "$tail_file"; } > "${tmp}.out"
    replace_file "${tmp}.out" "$file"
    rm -f "$tmp"
}

# _ensure_noninteractive_guard FILE
# Inserts [[ $- != *i* ]] && return immediately before the HEAD block if the
# guard is not already present anywhere in FILE.
_ensure_noninteractive_guard() {
    local file="$1" guard='[[ $- != *i* ]] && return'

    if grep -qE '\[\[ \$- != \*i\*' "$file" 2>/dev/null; then
        # Guard already present — was it added by a previous setup.sh run?
        # Preserve the flag across re-runs by reading the old manifest.
        if grep -qE '^GUARD_ADDED=true' "$MANIFEST_FILE" 2>/dev/null; then
            GUARD_ADDED=true
        fi
        return 0
    fi

    log_info "Non-interactive guard missing — adding it to ${file}…"
    local tmp
    tmp="$(mktemp)"
    local inserted=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $inserted -eq 0 && "$line" == "$BLOCK_HEAD_BEGIN" ]]; then
            printf '%s\n\n' "$guard"
            inserted=1
        fi
        echo "$line"
    done < "$file" > "$tmp"
    replace_file "$tmp" "$file"
    GUARD_ADDED=true
    log_ok "Non-interactive guard added"
}

# inject_bashrc — inject or update the managed blocks in ~/.bashrc.
inject_bashrc() {
    log_section "Configuring ~/.bashrc"

    local bashrc="${HOME}/.bashrc"

    if [[ ! -f "$bashrc" ]]; then
        log_info "~/.bashrc not found — creating a minimal one"
        if ! $DRY_RUN; then
            printf '%s\n' '# ~/.bashrc' '[[ $- != *i* ]] && return' > "$bashrc"
        fi
    fi

    # Back up whenever this run is about to change the file: either our blocks
    # are not there yet (first install), or they are there but differ from what
    # this version generates (an upgrade).
    #
    # Backing up only on first touch was not enough.  _rewrite_block replaces
    # the managed block wholesale, so an upgrade whose new block breaks the
    # prompt left no way back to the previous release — --restore would jump the
    # user all the way to their pre-install state.
    if ! grep -qF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null; then
        backup_if_exists "$bashrc"
    elif ! _blocks_are_current "$bashrc"; then
        _backup_before_upgrade "$bashrc"
    fi

    if $DRY_RUN; then
        if grep -qF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null; then
            log_dry "Update existing bash-customizations blocks in ${bashrc}"
        else
            log_dry "Inject bash-customizations blocks into ${bashrc}"
        fi
        if ! grep -qE '\[\[ \$- != \*i\*' "$bashrc" 2>/dev/null; then
            log_dry "Add non-interactive guard to ${bashrc}"
        fi
        return 0
    fi

    local tmp_head tmp_tail
    tmp_head="$(mktemp)"
    tmp_tail="$(mktemp)"
    _gen_head_block > "$tmp_head"
    _gen_tail_block > "$tmp_tail"

    if grep -qF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null; then
        log_info "Updating existing blocks in ${bashrc}…"
        _rewrite_block "$bashrc" "$BLOCK_HEAD_BEGIN" "$BLOCK_HEAD_END" "$tmp_head"
        if grep -qF "$BLOCK_TAIL_BEGIN" "$bashrc" 2>/dev/null; then
            _rewrite_block "$bashrc" "$BLOCK_TAIL_BEGIN" "$BLOCK_TAIL_END" "$tmp_tail"
        else
            { echo ""; cat "$tmp_tail"; } >> "$bashrc"
        fi
        log_ok "Blocks updated in ${bashrc}"
    else
        log_info "Injecting blocks into ${bashrc}…"
        # Edge case: tail block exists without head — strip it first
        if grep -qF "$BLOCK_TAIL_BEGIN" "$bashrc" 2>/dev/null; then
            local tmp_empty
            tmp_empty="$(mktemp)"
            _rewrite_block "$bashrc" "$BLOCK_TAIL_BEGIN" "$BLOCK_TAIL_END" "$tmp_empty"
            rm -f "$tmp_empty"
        fi
        _inject_blocks "$bashrc" "$tmp_head" "$tmp_tail"
        log_ok "Blocks injected into ${bashrc}"
    fi

    _ensure_noninteractive_guard "$bashrc"

    rm -f "$tmp_head" "$tmp_tail"
}

# ══════════════════════════════════════════════════════════════════════════════
# Dotfile deployment
# ══════════════════════════════════════════════════════════════════════════════

deploy_dotfiles() {
    log_section "Deploying dotfiles"

    # ~/.bashrc — inject managed blocks; never symlink
    inject_bashrc

    # ~/.bash/*.sh
    deploy_dir  "${REPO_DIR}/bash"    "${BASH_DIR}"

    # ~/.blerc
    deploy_file "${REPO_DIR}/.blerc"  "${HOME}/.blerc"

    # ~/.config/starship.toml
    deploy_file "${REPO_DIR}/starship.toml" "${XDG_CONFIG_HOME}/starship.toml"

    # Write manifest only on a real (non-dry-run) run.
    $DRY_RUN || write_manifest
}

# write_manifest — record everything we deployed so uninstall.sh can undo it.
write_manifest() {
    mkdir -p "${MANIFEST_DIR}"

    # A re-run usually creates no new backup (there is nothing left to displace
    # but our own symlinks).  Carry the existing pointer forward rather than
    # blanking it — it is the only record of which snapshot predates the very
    # first install, and uninstall.sh --restore is documented to use exactly
    # that one.  Without this, a second setup.sh silently downgraded --restore
    # to "whatever backup happens to be newest".
    local previous_backup=""
    if [[ -f "${MANIFEST_FILE}" ]]; then
        previous_backup="$(grep -m1 '^BACKUP=' "${MANIFEST_FILE}" 2>/dev/null || true)"
        previous_backup="${previous_backup#BACKUP=}"
    fi

    # Preserve previous manifests as a simple history (rotate: keep last 5).
    if [[ -f "${MANIFEST_FILE}" ]]; then
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"
        cp "${MANIFEST_FILE}" "${MANIFEST_FILE}.${ts}.bak"
        # Keep only the 5 most recent backups of the manifest.
        # Use find+sort instead of ls to handle filenames safely.
        local _old_baks
        _old_baks="$(find "${MANIFEST_DIR}" -maxdepth 1 -name 'manifest.*.bak' \
                     2>/dev/null | sort -r | tail -n +6)" || true
        if [[ -n "$_old_baks" ]]; then
            echo "$_old_baks" | xargs -r rm --
        fi
        unset _old_baks
    fi

    {
        echo "# bash-customizations install manifest"
        echo "# Written by setup.sh on $(date '+%Y-%m-%d %T')"
        echo "# Do not edit by hand — used by uninstall.sh and doctor.sh"
        echo "REPO=${REPO_DIR}"
        if $BACKUP_CREATED; then
            echo "BACKUP=${BACKUP_DIR}"
        else
            echo "BACKUP=${previous_backup}"
        fi
        $GUARD_ADDED && echo "GUARD_ADDED=true"
        # ${arr[@]+"${arr[@]}"} is the correct set -u safe idiom for arrays:
        # expands to nothing when the array is empty, not to a single empty string.
        for link in "${DEPLOYED_LINKS[@]+"${DEPLOYED_LINKS[@]}"}" ; do
            echo "LINK=${link}"
        done
    } > "${MANIFEST_FILE}"

    log_ok "Manifest written: ${MANIFEST_FILE}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Post-install verification
# ══════════════════════════════════════════════════════════════════════════════

verify() {
    log_section "Verification"

    # Two different kinds of "not ok":
    #   all_ok      — something this script was supposed to do and did not.
    #   advisories  — something it deliberately skipped because the environment
    #                 does not allow it (no root for a system package).  On a
    #                 sudo-less machine that is the expected outcome, not a
    #                 failed install, so it must not make the run exit non-zero.
    local all_ok=true
    local advisories=0

    _check() {
        local name="$1" cmd="$2"
        if has "$cmd"; then
            log_ok "${name}: $(ver "$cmd")"
        else
            log_warn "${name}: not found on PATH (${LOCAL_BIN} may need a new shell)"
            all_ok=false
        fi
    }

    _check "starship"       starship
    _check "fzf"            fzf
    _check "zoxide"         zoxide

    # ble.sh — not a binary, check for the file
    local blesh_file="${XDG_DATA_HOME}/blesh/ble.sh"
    if [[ -f "$blesh_file" ]]; then
        log_ok "ble.sh: ${blesh_file}"
    else
        log_warn "ble.sh: not found at ${blesh_file}"
        all_ok=false
    fi

    # bash-completion — check for the main script.  It lives in system paths and
    # needs root to install, so its absence is advisory rather than a failure.
    if [[ -f /usr/share/bash-completion/bash_completion ]] \
        || [[ -f /usr/local/share/bash-completion/bash_completion ]]; then
        log_ok "bash-completion: found"
    else
        log_warn "bash-completion: not found (needs root to install — optional)"
        (( advisories++ )) || true
    fi

    # ~/.bashrc — check for injected blocks
    if grep -qF "$BLOCK_HEAD_BEGIN" "${HOME}/.bashrc" 2>/dev/null \
        && grep -qF "$BLOCK_TAIL_BEGIN" "${HOME}/.bashrc" 2>/dev/null; then
        log_ok "~/.bashrc: managed blocks present"
    else
        log_warn "~/.bashrc: managed blocks not found"
        all_ok=false
    fi

    # Symlinked dotfiles
    for f in "${HOME}/.blerc" "${XDG_CONFIG_HOME}/starship.toml"; do
        if [[ -e "$f" ]]; then
            log_ok "Deployed: $f"
        else
            log_warn "Missing : $f"
            all_ok=false
        fi
    done

    # deploy_file already named every file as it linked it, so re-listing all
    # nine here just doubled the output.  What was never reported is the case
    # that matters: a module the repo has and $HOME does not.
    local missing_modules=() src module_count=0
    for src in "${REPO_DIR}"/bash/*.sh; do
        [[ -e "$src" ]] || continue
        (( module_count++ )) || true
        [[ -e "${BASH_DIR}/$(basename "$src")" ]] || missing_modules+=("$(basename "$src")")
    done
    if [[ ${#missing_modules[@]} -eq 0 ]]; then
        log_ok "Modules: ${module_count} deployed to ${BASH_DIR}"
    else
        log_warn "Modules: ${#missing_modules[@]} of ${module_count} missing — ${missing_modules[*]}"
        all_ok=false
    fi

    # Manifest
    if [[ -f "${MANIFEST_FILE}" ]]; then
        log_ok "Manifest: ${MANIFEST_FILE}"
    else
        log_warn "Manifest not written (dry-run or no files deployed)"
    fi

    echo
    if $all_ok; then
        if [[ "$advisories" -gt 0 ]]; then
            log_ok "All required checks passed (${advisories} optional item(s) skipped)."
        else
            log_ok "All checks passed."
        fi
        return 0
    fi

    log_warn "Some items need attention (see above)."
    log_warn "Run bash doctor.sh for a detailed diagnosis."
    log_warn "Open a new terminal or run:  source ~/.bashrc"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary banner
# ══════════════════════════════════════════════════════════════════════════════

print_banner() {
    log_banner "setup.sh"
    if $DRY_RUN;    then echo -e "${YELLOW}  DRY-RUN mode — no changes will be made${RESET}\n"; fi
    if $SKIP_TOOLS; then echo -e "${YELLOW}  --skip-tools — dotfile deployment only${RESET}\n"; fi
}

# print_done VERIFIED — closing summary.  VERIFIED is "true" only when every
# post-install check passed; anything else must not be announced as success.
print_done() {
    local verified="${1:-true}"

    if [[ "$verified" == "true" ]]; then
        echo -e "\n${BOLD}${GREEN}Setup complete!${RESET}"
    else
        echo -e "\n${BOLD}${YELLOW}Setup finished with warnings.${RESET}"
        echo -e "${YELLOW}  Your dotfiles are deployed, but some checks did not pass.${RESET}"
        echo -e "${YELLOW}  Run 'bash doctor.sh' to see exactly what is wrong.${RESET}"
    fi
    echo
    echo "  Next steps:"
    echo "  1. Open a new terminal."
    echo "     None of this is active in THIS shell — the config is read when a"
    echo "     shell starts, and yours started before it existed."
    echo "     (Or run: source ~/.bashrc)"
    echo "  2. Set your terminal's font to a Nerd Font, or the prompt icons will"
    echo "     show as empty boxes: https://www.nerdfonts.com/font-downloads"
    if $BACKUP_CREATED; then
        echo "  3. Your old dotfiles were backed up to: ${BACKUP_DIR}"
        echo "     To restore them: bash uninstall.sh --restore"
    fi
    echo
    echo "  Useful commands after setup:"
    echo "    cheatsheet     — every alias and function this added, with descriptions"
    echo "    cheatsheet git — the same list, filtered"
    echo "    z <dir>        — jump to directory (zoxide)"
    echo "    zi             — interactive directory jump (zoxide + fzf)"
    echo "    CTRL-R         — fuzzy history search (fzf / ble.sh)"
    echo "    CTRL-T         — fuzzy file picker (fzf)"
    echo "    ALT-C          — fuzzy cd (fzf)"
    echo "    starship explain — show what each prompt segment means"
}

# ══════════════════════════════════════════════════════════════════════════════
# Locale
# ══════════════════════════════════════════════════════════════════════════════

# ensure_locale — generate en_US.UTF-8 if it is missing.
#
# Why this matters:
#   ble.sh checks LC_CTYPE on startup.  If the locale is absent it falls back
#   to single-byte mode, which prevents it from consuming CSI escape sequences
#   (terminal device-attributes and cursor-position replies).  Those sequences
#   then leak into the readline buffer and appear as literal garbage characters
#   (">0;10;1c", "2;1R", etc.) right after the shell prompt.
ensure_locale() {
    log_section "Locale"

    # Already installed?
    if locale -a 2>/dev/null | grep -qiE 'en_US\.(UTF-8|utf8)'; then
        log_ok "en_US.UTF-8 locale is available"
        return 0
    fi

    log_warn "en_US.UTF-8 locale is NOT installed."
    log_warn "Without it, ble.sh falls back to single-byte mode, causing"
    log_warn "garbage escape sequences in the prompt ('>0;10;1c', '2;1R', …)"

    if $DRY_RUN; then
        log_dry "locale-gen en_US.UTF-8"
        log_dry "update-locale LANG=en_US.UTF-8"
        return 0
    fi

    # locale-gen is available on Debian/Ubuntu/WSL — use it automatically.
    # This runs before every installer, so it must never abort the run: a
    # missing locale degrades ble.sh's rendering, it does not break the setup.
    if has locale-gen && root_available; then
        log_info "Generating en_US.UTF-8 locale (needs root)…"
        if _as_root locale-gen en_US.UTF-8 && _as_root update-locale LANG=en_US.UTF-8; then
            log_ok "Locale generated. Open a new terminal to apply."
        else
            log_warn "Locale generation failed — continuing."
            log_warn "Fix it later with: sudo locale-gen en_US.UTF-8"
        fi
    elif has locale-gen; then
        log_warn "locale-gen needs root and no sudo is available — skipping."
        log_warn "Fix it later with: sudo locale-gen en_US.UTF-8"
    else
        # Other distros: print manual instructions.
        log_warn "locale-gen not found. Generate the locale manually:"
        log_warn "  Fedora/RHEL : sudo dnf install -y glibc-langpack-en"
        log_warn "  Arch        : uncomment en_US.UTF-8 in /etc/locale.gen && sudo locale-gen"
        log_warn "  macOS       : locale is managed by the OS; no action needed"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
    print_banner
    check_prerequisites
    ensure_locale

    if ! $SKIP_TOOLS; then
        install_starship
        install_blesh
        install_bash_completion
        install_fzf
        install_zoxide
    fi

    deploy_dotfiles

    # verify() returns non-zero when something is off; don't hide that behind a
    # green "Setup complete!" banner.
    local verified=true
    verify || verified=false

    if ! $DRY_RUN; then print_done "$verified"; fi
    $verified
}

main "$@"
