#!/usr/bin/env bash
# uninstall.sh
#
# Safely remove the bash-customizations dotfiles and, optionally, the tools.
#
# What it does:
#   1. Reads the install manifest (~/.local/share/bash-customizations/manifest)
#      to know exactly which symlinks setup.sh created.
#   2. Verifies each symlink actually points back into this repo before touching
#      it (will never remove a file it didn't create).
#   3. Removes those symlinks.
#   4. Optionally restores the most recent (or a chosen) backup.
#   5. Optionally removes tool binaries (starship, fzf, zoxide, ble.sh).
#
# Usage:
#   bash uninstall.sh                   # remove symlinks only (leaves backups)
#   bash uninstall.sh --restore         # remove symlinks + restore latest backup
#   bash uninstall.sh --restore=20250604_142301  # restore a specific backup
#   bash uninstall.sh --purge-tools     # also remove tool binaries
#   bash uninstall.sh --list-backups    # list available backups and exit
#   bash uninstall.sh --dry-run         # show what would happen, change nothing
#
# Safety rules:
#   - Never removes a file that is not a symlink into this repo.
#   - Never touches system-level files (bash-completion stays — it's a package).
#   - Warns loudly if the manifest is missing and falls back to known defaults.
#   - Always asks for confirmation before destructive --purge-tools steps.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
LOCAL_BIN="${HOME}/.local/bin"
BACKUP_BASE="${HOME}/.bash_backup"

MANIFEST_DIR="${HOME}/.local/share/bash-customizations"
MANIFEST_FILE="${MANIFEST_DIR}/manifest"

# Block markers (must match setup.sh)
BLOCK_HEAD_BEGIN="# === BEGIN bash-customizations ==="
BLOCK_HEAD_END="# === END bash-customizations ==="
BLOCK_TAIL_BEGIN="# === BEGIN bash-customizations-attach ==="
BLOCK_TAIL_END="# === END bash-customizations-attach ==="

# Flags
DRY_RUN=false
PURGE_TOOLS=false
RESTORE=false
RESTORE_TIMESTAMP=""    # empty = use latest
LIST_BACKUPS=false
RESTORE_DIR=""          # set by resolve_backup_dir; declared here to avoid set -u hazard

# ══════════════════════════════════════════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
log_dry()     { echo -e "${YELLOW}[DRY]${RESET}   $*"; }
log_skip()    { echo -e "        (skipped) $*"; }

run() { if $DRY_RUN; then log_dry "$*"; return 0; fi; "$@"; }

# confirm PROMPT — ask yes/no; return 0 for yes, 1 for no.
confirm() {
    local prompt="${1:-Are you sure?} [y/N] "
    local reply
    read -r -p "$(echo -e "${YELLOW}${prompt}${RESET}")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ══════════════════════════════════════════════════════════════════════════════

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)        DRY_RUN=true ;;
            --purge-tools)    PURGE_TOOLS=true ;;
            --restore)        RESTORE=true ;;
            --restore=*)      RESTORE=true; RESTORE_TIMESTAMP="${arg#--restore=}" ;;
            --list-backups)   LIST_BACKUPS=true ;;
            -h|--help)
                echo "Usage: bash uninstall.sh [options]"
                echo
                echo "Options:"
                echo "  --dry-run               Show what would happen, change nothing"
                echo "  --restore               Remove symlinks + restore latest backup"
                echo "  --restore=TIMESTAMP     Restore a specific backup (see --list-backups)"
                echo "  --purge-tools           Also remove tool binaries (starship, fzf, zoxide, ble.sh)"
                echo "  --list-backups          List available backups and exit"
                echo
                echo "Examples:"
                echo "  bash uninstall.sh --dry-run"
                echo "  bash uninstall.sh --restore"
                echo "  bash uninstall.sh --restore=20250604_142301 --purge-tools"
                exit 0
                ;;
            *)
                log_error "Unknown argument: $arg  (use --help)"
                exit 1
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Manifest
# ══════════════════════════════════════════════════════════════════════════════

# Populated by read_manifest or fall back to known defaults.
MANIFEST_REPO=""
MANIFEST_BACKUP=""
MANIFEST_LINKS=()
MANIFEST_GUARD_ADDED=false

read_manifest() {
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        log_warn "Manifest not found at: ${MANIFEST_FILE}"
        log_warn "Falling back to known default deployment targets."
        _use_default_targets
        return
    fi

    log_info "Reading manifest: ${MANIFEST_FILE}"
    while IFS='=' read -r key value; do
        # Skip blank lines and comments.
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            REPO)         MANIFEST_REPO="$value"         ;;
            BACKUP)       MANIFEST_BACKUP="$value"       ;;
            LINK)         MANIFEST_LINKS+=("$value")     ;;
            GUARD_ADDED)  [[ "$value" == "true" ]] && MANIFEST_GUARD_ADDED=true ;;
        esac
    done < "$MANIFEST_FILE"

    if [[ -z "$MANIFEST_REPO" ]]; then
        log_warn "Manifest has no REPO entry. Falling back to defaults."
        _use_default_targets
    fi
}

# _use_default_targets — hardcoded list of every file setup.sh deploys,
# used when no manifest exists.
_use_default_targets() {
    MANIFEST_REPO="${REPO_DIR}"
    MANIFEST_BACKUP=""
    MANIFEST_LINKS=(
        "${HOME}/.blerc"
        "${XDG_CONFIG_HOME}/starship.toml"
        "${HOME}/.bash/aliases.sh"
        "${HOME}/.bash/bindings.sh"
        "${HOME}/.bash/completion.sh"
        "${HOME}/.bash/exports.sh"
        "${HOME}/.bash/functions.sh"
        "${HOME}/.bash/history.sh"
        "${HOME}/.bash/init.sh"
        "${HOME}/.bash/prompt.sh"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# Backup listing
# ══════════════════════════════════════════════════════════════════════════════

list_backups() {
    log_section "Available backups"

    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_warn "No backup directory found at: ${BACKUP_BASE}"
        return 0
    fi

    local found=false
    while IFS= read -r dir; do
        local ts
        ts="$(basename "$dir")"
        local files
        files="$(find "$dir" -maxdepth 2 -not -type d 2>/dev/null | wc -l | tr -d ' ')"
        echo "  ${CYAN}${ts}${RESET}  (${files} files)  →  ${dir}"
        found=true
    done < <(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d | sort -r)

    if ! $found; then
        log_info "No backups found."
    fi
}

# resolve_backup_dir — set RESTORE_DIR based on RESTORE_TIMESTAMP or latest.
resolve_backup_dir() {
    local restore_dir

    if [[ -n "$RESTORE_TIMESTAMP" ]]; then
        restore_dir="${BACKUP_BASE}/${RESTORE_TIMESTAMP}"
        if [[ ! -d "$restore_dir" ]]; then
            log_error "Backup not found: ${restore_dir}"
            log_error "Run: bash uninstall.sh --list-backups"
            exit 1
        fi
    else
        # Use backup recorded in manifest first; fall back to newest on disk.
        if [[ -n "$MANIFEST_BACKUP" && -d "$MANIFEST_BACKUP" ]]; then
            restore_dir="$MANIFEST_BACKUP"
        else
            restore_dir="$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
                | sort -r | head -1)"
        fi

        if [[ -z "$restore_dir" || ! -d "$restore_dir" ]]; then
            log_error "No backups found in ${BACKUP_BASE}."
            log_error "Cannot restore.  The state before setup.sh ran is gone."
            exit 1
        fi
    fi

    RESTORE_DIR="$restore_dir"
}

# ══════════════════════════════════════════════════════════════════════════════
# Symlink removal
# ══════════════════════════════════════════════════════════════════════════════

remove_symlinks() {
    log_section "Removing managed symlinks"

    local removed=0 skipped=0 not_found=0

    for link in "${MANIFEST_LINKS[@]}"; do
        if [[ ! -e "$link" && ! -L "$link" ]]; then
            log_skip "Not found (already removed?): $link"
            (( not_found++ )) || true
            continue
        fi

        if [[ ! -L "$link" ]]; then
            log_warn "Not a symlink — skipping (will not remove): $link"
            (( skipped++ )) || true
            continue
        fi

        # Safety check: only remove symlinks that point into our repo.
        # readlink -f is GNU-only; fall back to readlink without -f on macOS.
        local target
        target="$(readlink -f "$link" 2>/dev/null \
               || readlink "$link" 2>/dev/null \
               || true)"
        if [[ -z "$target" ]]; then
            log_warn "Could not resolve symlink target — skipping: $link"
            (( skipped++ )) || true
            continue
        fi
        if [[ "$target" != "${MANIFEST_REPO}/"* && "$target" != "${MANIFEST_REPO}" ]]; then
            log_warn "Points outside repo — skipping: $link → $target"
            (( skipped++ )) || true
            continue
        fi

        run rm "$link"
        log_ok "Removed: $link"
        (( removed++ )) || true
    done

    # Remove ~/.bash/ directory if it's now empty.
    if [[ -d "${HOME}/.bash" ]]; then
        local remaining
        remaining="$(find "${HOME}/.bash" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$remaining" -eq 0 ]]; then
            run rmdir "${HOME}/.bash"
            log_ok "Removed empty dir: ${HOME}/.bash"
        else
            log_info "Kept non-empty dir: ${HOME}/.bash  (${remaining} file(s) remain)"
        fi
    fi

    echo
    log_info "Summary: removed=${removed}  skipped=${skipped}  not_found=${not_found}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Backup restore
# ══════════════════════════════════════════════════════════════════════════════

restore_backup() {
    log_section "Restoring backup"

    resolve_backup_dir   # sets RESTORE_DIR

    log_info "Restoring from: ${RESTORE_DIR}"
    echo

    local count=0
    while IFS= read -r src_file; do
        # Reconstruct destination by stripping the backup dir prefix.
        local rel_path="${src_file#"${RESTORE_DIR}/"}"
        local dest="${HOME}/${rel_path}"

        # Don't overwrite a non-symlink that already exists with the same name
        # (shouldn't happen, but be safe).
        if [[ -e "$dest" && ! -L "$dest" ]]; then
            log_warn "Skipping restore of $dest (already exists as a real file)"
            continue
        fi

        run mkdir -p "$(dirname "$dest")"
        run cp -a "$src_file" "$dest"
        log_ok "Restored: $dest"
        (( count++ )) || true
    done < <(find "$RESTORE_DIR" -not -type d | sort)

    echo
    log_ok "Restored ${count} file(s) from ${RESTORE_DIR}"
    log_info "Open a new terminal (or: exec bash) to apply the restored config."
}

# ══════════════════════════════════════════════════════════════════════════════
# Tool purge
# ══════════════════════════════════════════════════════════════════════════════

purge_tools() {
    log_section "Purging tool binaries"

    echo -e "${YELLOW}This will remove the following binaries and directories:${RESET}"
    echo "  ~/.local/bin/starship"
    echo "  ~/.local/bin/fzf     (and ~/.fzf/ if it exists)"
    echo "  ~/.local/bin/zoxide"
    echo "  ~/.local/share/blesh/"
    echo
    echo -e "${YELLOW}bash-completion is a system package and will NOT be touched.${RESET}"
    echo

    if ! $DRY_RUN; then
        confirm "Permanently remove these files?" || { log_info "Purge cancelled."; return 0; }
    fi

    # ── starship ──────────────────────────────────────────────────────────────
    _remove_bin "starship"

    # ── fzf ───────────────────────────────────────────────────────────────────
    _remove_bin "fzf"
    if [[ -d "${HOME}/.fzf" ]]; then
        run rm -rf "${HOME}/.fzf"
        log_ok "Removed: ~/.fzf/"
    fi

    # ── zoxide ────────────────────────────────────────────────────────────────
    _remove_bin "zoxide"

    # ── ble.sh ────────────────────────────────────────────────────────────────
    local blesh_dir="${XDG_DATA_HOME}/blesh"
    if [[ -d "$blesh_dir" ]]; then
        # Warn if ble.sh has an active session in this terminal.  Removing its
        # directory while it is running deletes the temp files it needs, causing
        # a flood of "No such file or directory" errors on every prompt redraw.
        # The errors are harmless and stop as soon as a new terminal is opened.
        local blesh_run="${blesh_dir}/run"
        if [[ -d "$blesh_run" ]] \
            && [[ -n "$(ls -A "$blesh_run" 2>/dev/null)" ]]; then
            echo
            log_warn "ble.sh is active in this shell session."
            log_warn "After removal you will see 'No such file or directory' errors"
            log_warn "on each prompt until you open a new terminal. This is expected."
            echo
        fi
        run rm -rf "$blesh_dir"
        log_ok "Removed: ${blesh_dir}"
    else
        log_skip "ble.sh dir not found: ${blesh_dir}"
    fi
}

_remove_bin() {
    local name="$1"
    local bin_path="${LOCAL_BIN}/${name}"
    if [[ -f "$bin_path" ]]; then
        run rm "$bin_path"
        log_ok "Removed: ${bin_path}"
    else
        # Also check if it's on PATH elsewhere.
        local found_path
        found_path="$(command -v "$name" 2>/dev/null || true)"
        if [[ -n "$found_path" ]]; then
            log_warn "${name} found at ${found_path} (outside ~/.local/bin — not removed)"
            log_warn "Remove it manually if you want to fully purge ${name}."
        else
            log_skip "Binary not found: ${bin_path}"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# .bashrc block removal
# ══════════════════════════════════════════════════════════════════════════════

remove_bashrc_blocks() {
    log_section "Removing bash-customizations blocks from ~/.bashrc"

    local bashrc="${HOME}/.bashrc"

    if [[ ! -f "$bashrc" ]]; then
        log_info "~/.bashrc does not exist — nothing to remove"
        return 0
    fi

    local head_found=false tail_found=false
    grep -qF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null && head_found=true
    grep -qF "$BLOCK_TAIL_BEGIN" "$bashrc" 2>/dev/null && tail_found=true

    if ! $head_found && ! $tail_found; then
        log_info "No bash-customizations blocks found in ~/.bashrc"
        return 0
    fi

    if $DRY_RUN; then
        $head_found && log_dry "Remove HEAD block from ~/.bashrc"
        $tail_found && log_dry "Remove TAIL block from ~/.bashrc"
        $MANIFEST_GUARD_ADDED && log_dry "Remove non-interactive guard from ~/.bashrc (added by setup.sh)"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    local in_block=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$BLOCK_HEAD_BEGIN" || "$line" == "$BLOCK_TAIL_BEGIN" ]]; then
            in_block=1
            continue
        fi
        if [[ "$line" == "$BLOCK_HEAD_END" || "$line" == "$BLOCK_TAIL_END" ]]; then
            in_block=0
            continue
        fi
        if [[ $in_block -eq 0 ]]; then
            # Remove the guard only if setup.sh added it (tracked in manifest).
            if $MANIFEST_GUARD_ADDED && [[ "$line" =~ ^\[\[.*\$-.*\*i\*.*return ]]; then
                continue
            fi
            echo "$line"
        fi
    done < "$bashrc" > "$tmp"

    mv "$tmp" "$bashrc"
    log_ok "Removed bash-customizations blocks from ~/.bashrc"
    $MANIFEST_GUARD_ADDED && log_ok "Removed non-interactive guard from ~/.bashrc"
}

# ══════════════════════════════════════════════════════════════════════════════
# Manifest cleanup
# ══════════════════════════════════════════════════════════════════════════════

remove_manifest() {
    if [[ -f "$MANIFEST_FILE" ]]; then
        run rm "$MANIFEST_FILE"
        log_ok "Removed manifest: ${MANIFEST_FILE}"
    fi
    # Remove manifest dir if empty.
    if [[ -d "$MANIFEST_DIR" ]]; then
        local remaining
        remaining="$(find "$MANIFEST_DIR" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$remaining" -eq 0 ]]; then
            run rmdir "$MANIFEST_DIR"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Banner
# ══════════════════════════════════════════════════════════════════════════════

print_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║       bash-customizations  uninstall.sh          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    if $DRY_RUN; then echo -e "${YELLOW}  DRY-RUN mode — no changes will be made${RESET}\n"; fi
}

print_done() {
    echo -e "\n${BOLD}${GREEN}Uninstall complete.${RESET}"
    echo
    if $RESTORE; then
        echo "  Your previous config has been restored."
        echo "  Open a new terminal to apply it."
    else
        echo "  Symlinks removed. Your shell will use the system defaults"
        echo "  until you restore a backup or run setup.sh again."
    fi
    if $PURGE_TOOLS; then
        echo
        echo "  Tool binaries have been removed."
        echo
        echo "  If you see 'No such file or directory' errors on the prompt:"
        echo "  that is ble.sh losing its temp files mid-session. Open a new"
        echo "  terminal and they will stop. Nothing is broken."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
    print_banner

    if $LIST_BACKUPS; then
        list_backups
        exit 0
    fi

    read_manifest

    # Confirmation gate for non-dry-run interactive runs.
    if ! $DRY_RUN; then
        echo -e "${YELLOW}This will:${RESET}"
        if [[ ${#MANIFEST_LINKS[@]} -gt 0 ]]; then
            echo "  Remove the following managed symlinks:"
            for link in "${MANIFEST_LINKS[@]}"; do
                echo "    $link"
            done
        fi
        if grep -qF "$BLOCK_HEAD_BEGIN" "${HOME}/.bashrc" 2>/dev/null \
            || grep -qF "$BLOCK_TAIL_BEGIN" "${HOME}/.bashrc" 2>/dev/null; then
            echo "  Remove bash-customizations blocks from ~/.bashrc"
        fi
        if $MANIFEST_GUARD_ADDED; then
            echo "  Remove non-interactive guard added by setup.sh from ~/.bashrc"
        fi
        echo
        confirm "Proceed with removal?" || { log_info "Aborted."; exit 0; }
        echo
    fi

    remove_symlinks
    remove_bashrc_blocks

    if $RESTORE; then
        restore_backup
    fi

    if $PURGE_TOOLS; then
        purge_tools
    fi

    remove_manifest

    if ! $DRY_RUN; then print_done; fi
}

main "$@"
