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
#   4. Optionally restores a backup — the one recorded in the manifest by
#      default (NOT simply the newest on disk), or one chosen by timestamp.
#   5. Optionally removes tool binaries (starship, fzf, zoxide, ble.sh).
#
# Usage:
#   bash uninstall.sh                   # remove symlinks only (leaves backups)
#   bash uninstall.sh --restore         # remove symlinks + restore the backup
#   bash uninstall.sh --restore=20250604_142301  # restore a specific backup
#   bash uninstall.sh --restore-only    # restore a backup, keep the install
#   bash uninstall.sh --purge-tools     # also remove tool binaries
#   bash uninstall.sh --list-backups    # list available backups and exit
#   bash uninstall.sh --prune-backups   # delete all but the newest 5 backups
#   bash uninstall.sh --delete-backup=TS  # delete one backup and exit
#   bash uninstall.sh --dry-run         # show what would happen, change nothing
#   bash uninstall.sh --yes             # never prompt (required without a TTY)
#
# Safety rules:
#   - Never removes a file that is not a symlink into this repo.
#   - Never touches system-level files (bash-completion stays — it's a package).
#   - Warns loudly if the manifest is missing and falls back to known defaults.
#   - Always asks for confirmation before destructive steps; without a terminal
#     it refuses and exits non-zero rather than pretending to have run.
#   - A restore overwrites real files (that is the point), but snapshots what it
#     replaces into ~/.bash_backup/<ts>-pre-restore/ first.
#
# Exit codes:
#   0  — the requested action completed
#   1  — the action could not be completed (bad argument, no backup, no TTY)
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

# How many backups --prune-backups keeps.  Mirrors the manifest rotation in
# setup.sh so both kinds of history are capped the same way.
PRUNE_KEEP_DEFAULT=5

# Flags
DRY_RUN=false
PURGE_TOOLS=false
RESTORE=false
RESTORE_ONLY=false      # restore a backup without uninstalling anything
RESTORE_TIMESTAMP=""    # empty = manifest's backup, else newest on disk
LIST_BACKUPS=false
PRUNE_BACKUPS=false
PRUNE_KEEP="$PRUNE_KEEP_DEFAULT"
DELETE_BACKUP=""        # timestamp of a single backup to delete
ASSUME_YES=false
RESTORE_DIR=""          # set by resolve_backup_dir; declared here to avoid set -u hazard
PURGED=false            # true once tool binaries were actually removed

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

# run CMD… — execute unless this is a dry run.  Deliberately silent: every
# mutation is announced by the report() call that follows it, in the caller's
# words rather than as a raw command line.
run() { $DRY_RUN || "$@"; }

# report DONE PLANNED — state what happened, honestly.
# Under --dry-run nothing was removed, so saying "Removed: x" would be a lie;
# every mutating step reports through this instead of a bare log_ok.
report() { if $DRY_RUN; then log_dry "$2"; else log_ok "$1"; fi; }

# confirm PROMPT — ask yes/no; return 0 for yes, 1 for no.
#
# --yes answers everything.  Without a terminal (CI, `make` in a pipe,
# `ssh host 'make uninstall'`) there is nobody to ask: refuse and exit 1 rather
# than reporting success for an action that never happened.
confirm() {
    local prompt="${1:-Are you sure?}"

    if $ASSUME_YES; then
        log_info "${prompt}  (--yes)"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_error "${prompt}"
        log_error "No terminal available to confirm. Re-run with --yes to proceed non-interactively."
        exit 1
    fi

    local reply
    read -r -p "$(echo -e "${YELLOW}${prompt} [y/N] ${RESET}")" reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ══════════════════════════════════════════════════════════════════════════════

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)        DRY_RUN=true ;;
            --yes|-y)         ASSUME_YES=true ;;
            --purge-tools)    PURGE_TOOLS=true ;;
            --restore)        RESTORE=true ;;
            --restore=*)      RESTORE=true; RESTORE_TIMESTAMP="${arg#--restore=}" ;;
            --restore-only)   RESTORE=true; RESTORE_ONLY=true ;;
            --restore-only=*) RESTORE=true; RESTORE_ONLY=true
                              RESTORE_TIMESTAMP="${arg#--restore-only=}" ;;
            --list-backups)   LIST_BACKUPS=true ;;
            --prune-backups)  PRUNE_BACKUPS=true ;;
            --prune-backups=*)
                PRUNE_BACKUPS=true; PRUNE_KEEP="${arg#--prune-backups=}"
                if ! [[ "$PRUNE_KEEP" =~ ^[0-9]+$ ]]; then
                    log_error "--prune-backups expects a number, got: '${PRUNE_KEEP}'"
                    exit 1
                fi
                ;;
            --delete-backup=*) DELETE_BACKUP="${arg#--delete-backup=}" ;;
            -h|--help)
                echo "Usage: bash uninstall.sh [options]"
                echo
                echo "Options:"
                echo "  --dry-run               Show what would happen, change nothing"
                echo "  -y, --yes               Answer every prompt with yes (required without a TTY)"
                echo "  --restore               Remove symlinks + restore a backup"
                echo "  --restore=TIMESTAMP     Restore a specific backup (see --list-backups)"
                echo "  --restore-only[=TS]     Restore a backup WITHOUT uninstalling"
                echo "  --purge-tools           Also remove tool binaries (starship, fzf, zoxide, ble.sh)"
                echo "  --list-backups          List available backups and exit"
                echo "  --prune-backups[=N]     Delete all but the newest N backups (default ${PRUNE_KEEP_DEFAULT}) and exit"
                echo "  --delete-backup=TS      Delete one backup by timestamp and exit"
                echo "  -h, --help              Show this help and exit"
                echo
                echo "Which backup --restore picks: the one recorded in the install"
                echo "manifest (the run that produced your current setup); if that is"
                echo "gone, the newest on disk.  Use --restore=TIMESTAMP to be explicit."
                echo
                echo "Exit codes: 0 = action completed, 1 = could not complete"
                echo
                echo "Examples:"
                echo "  bash uninstall.sh --dry-run"
                echo "  bash uninstall.sh --restore"
                echo "  bash uninstall.sh --restore=20250604_142301 --purge-tools"
                echo "  bash uninstall.sh --restore-only=20250604_142301"
                echo "  bash uninstall.sh --prune-backups=3"
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

# _backup_dirs — print every backup directory, newest first, one per line.
_backup_dirs() {
    [[ -d "$BACKUP_BASE" ]] || return 0
    find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r
}

list_backups() {
    log_section "Available backups"

    if [[ ! -d "$BACKUP_BASE" ]]; then
        log_warn "No backup directory found at: ${BACKUP_BASE}"
        return 0
    fi

    local found=false
    while IFS= read -r dir; do
        local ts files size marker=""
        ts="$(basename "$dir")"
        files="$(find "$dir" -not -type d 2>/dev/null | wc -l | tr -d ' ')"
        size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
        # Point at the one --restore would choose by default, so the timestamp
        # the user copies is the one they actually mean.
        [[ "$dir" == "$MANIFEST_BACKUP" ]] && marker="  ${GREEN}← current install${RESET}"
        echo -e "  ${CYAN}${ts}${RESET}  ${files} file(s), ${size:-?}${marker}"
        found=true
    done < <(_backup_dirs)

    if ! $found; then
        log_info "No backups found."
        return 0
    fi

    echo
    log_info "Restore one with:  bash uninstall.sh --restore-only=TIMESTAMP"
    log_info "Delete one with:   bash uninstall.sh --delete-backup=TIMESTAMP"
}

# prune_backups — keep the newest PRUNE_KEEP backups, delete the rest.
prune_backups() {
    log_section "Pruning backups (keeping newest ${PRUNE_KEEP})"

    local -a doomed=()
    while IFS= read -r dir; do
        doomed+=("$dir")
    done < <(_backup_dirs | tail -n "+$(( PRUNE_KEEP + 1 ))")

    if [[ ${#doomed[@]} -eq 0 ]]; then
        log_ok "Nothing to prune — ${PRUNE_KEEP} or fewer backups exist."
        return 0
    fi

    echo -e "${YELLOW}This will permanently delete ${#doomed[@]} backup(s):${RESET}"
    local dir
    for dir in "${doomed[@]}"; do
        echo "  $(basename "$dir")"
    done
    echo

    if ! $DRY_RUN; then
        confirm "Delete these backups?" || { log_info "Prune cancelled."; return 0; }
    fi

    for dir in "${doomed[@]}"; do
        run rm -rf "$dir"
        report "Deleted backup: $(basename "$dir")" "Would delete backup: $(basename "$dir")"
    done
}

# delete_backup — remove a single backup by timestamp.
delete_backup() {
    local ts="$1"
    local dir="${BACKUP_BASE}/${ts}"

    log_section "Deleting backup ${ts}"

    if [[ ! -d "$dir" ]]; then
        log_error "Backup not found: ${dir}"
        log_error "Run: bash uninstall.sh --list-backups"
        exit 1
    fi

    if [[ "$dir" == "$MANIFEST_BACKUP" ]]; then
        log_warn "This is the backup recorded for your current install."
        log_warn "Deleting it means --restore can no longer undo setup.sh."
    fi

    if ! $DRY_RUN; then
        confirm "Permanently delete ${ts}?" || { log_info "Cancelled."; return 0; }
    fi

    run rm -rf "$dir"
    report "Deleted backup: ${ts}" "Would delete backup: ${ts}"
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
    local -a removed_paths=()

    # ${arr[@]+"${arr[@]}"} is the set -u safe idiom for a possibly-empty array
    # on Bash < 4.4 — a manifest with no LINK= lines must not abort the script.
    for link in "${MANIFEST_LINKS[@]+"${MANIFEST_LINKS[@]}"}"; do
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
        report "Removed: $link" "Would remove: $link"
        removed_paths+=("$link")
        (( removed++ )) || true
    done

    # Remove ~/.bash/ directory if it is (or would become) empty.
    # Counting live files would be wrong under --dry-run, where nothing was
    # actually removed — count what would be left instead.
    if [[ -d "${HOME}/.bash" ]]; then
        local remaining=0 entry planned candidate
        while IFS= read -r entry; do
            planned=false
            for candidate in "${removed_paths[@]+"${removed_paths[@]}"}"; do
                [[ "$entry" == "$candidate" ]] && { planned=true; break; }
            done
            $planned || (( remaining++ )) || true
        done < <(find "${HOME}/.bash" -mindepth 1 2>/dev/null)

        if [[ "$remaining" -eq 0 ]]; then
            run rmdir "${HOME}/.bash"
            report "Removed empty dir: ${HOME}/.bash" "Would remove empty dir: ${HOME}/.bash"
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

# restore_backup — copy every file in RESTORE_DIR back into $HOME.
#
# RESTORE_DIR is resolved and validated by main() before anything is mutated,
# so a bad --restore=TIMESTAMP can never leave a half-uninstalled system.
#
# A backup exists to be restored, including over real files.  ~/.bashrc is the
# important case: setup.sh never symlinks it (it injects blocks instead), so it
# is always a real file at restore time.  Refusing to overwrite real files —
# which this function used to do — meant the one file that cannot be
# reconstructed was the one file never restored.  Instead, whatever is about to
# be replaced is snapshotted first, so the restore itself stays undoable.
restore_backup() {
    log_section "Restoring backup"

    log_info "Restoring from: ${RESTORE_DIR}"

    local pre_restore
    pre_restore="${BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)-pre-restore"
    local snapshotted=0 count=0

    while IFS= read -r src_file; do
        # Reconstruct destination by stripping the backup dir prefix.
        local rel_path="${src_file#"${RESTORE_DIR}/"}"
        local dest="${HOME}/${rel_path}"

        if [[ -f "$dest" && ! -L "$dest" ]]; then
            local snapshot="${pre_restore}/${rel_path}"
            run mkdir -p "$(dirname "$snapshot")"
            run cp -a "$dest" "$snapshot"
            (( snapshotted++ )) || true
        fi

        # cp writes *through* a symlink to its target; drop it first so the
        # restored file lands where it belongs.
        [[ -L "$dest" ]] && run rm -f "$dest"

        run mkdir -p "$(dirname "$dest")"
        run cp -a "$src_file" "$dest"
        report "Restored: $dest" "Would restore: $dest"
        (( count++ )) || true
    done < <(find "$RESTORE_DIR" -not -type d | sort)

    echo
    if [[ "$count" -eq 0 ]]; then
        log_warn "Backup ${RESTORE_DIR} contained no files — nothing restored."
        return 0
    fi

    report "Restored ${count} file(s) from ${RESTORE_DIR}" \
           "Would restore ${count} file(s) from ${RESTORE_DIR}"
    if [[ "$snapshotted" -gt 0 ]]; then
        log_info "Replaced ${snapshotted} existing file(s); their previous contents are in:"
        log_info "  ${pre_restore}"
    fi
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
    PURGED=true

    # ── starship ──────────────────────────────────────────────────────────────
    _remove_bin "starship"

    # ── fzf ───────────────────────────────────────────────────────────────────
    _remove_bin "fzf"
    if [[ -d "${HOME}/.fzf" ]]; then
        run rm -rf "${HOME}/.fzf"
        report "Removed: ~/.fzf/" "Would remove: ~/.fzf/"
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
        report "Removed: ${blesh_dir}" "Would remove: ${blesh_dir}"
    else
        log_skip "ble.sh dir not found: ${blesh_dir}"
    fi
}

_remove_bin() {
    local name="$1"
    local bin_path="${LOCAL_BIN}/${name}"
    # -e is false for a dangling symlink (setup.sh links ~/.local/bin/fzf into
    # ~/.fzf/bin), so test -L too or the link is left on PATH forever.
    if [[ -e "$bin_path" || -L "$bin_path" ]]; then
        run rm "$bin_path"
        report "Removed: ${bin_path}" "Would remove: ${bin_path}"
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

    # mktemp creates 0600 files and mv preserves that mode, which would quietly
    # tighten ~/.bashrc's permissions on every run — capture and restore them.
    local mode
    mode="$(stat -c '%a' "$bashrc" 2>/dev/null || stat -f '%Lp' "$bashrc" 2>/dev/null || echo 644)"

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
    chmod "$mode" "$bashrc"
    log_ok "Removed bash-customizations blocks from ~/.bashrc"
    $MANIFEST_GUARD_ADDED && log_ok "Removed non-interactive guard from ~/.bashrc"
}

# ══════════════════════════════════════════════════════════════════════════════
# Manifest cleanup
# ══════════════════════════════════════════════════════════════════════════════

remove_manifest() {
    if [[ -f "$MANIFEST_FILE" ]]; then
        run rm "$MANIFEST_FILE"
        report "Removed manifest: ${MANIFEST_FILE}" "Would remove manifest: ${MANIFEST_FILE}"
    fi

    # setup.sh rotates old manifests as manifest.<ts>.bak.  Leaving them behind
    # meant the directory was never empty and the rmdir below was dead code.
    local bak
    while IFS= read -r bak; do
        run rm -f "$bak"
        report "Removed rotated manifest: $(basename "$bak")" \
               "Would remove rotated manifest: $(basename "$bak")"
    done < <(find "$MANIFEST_DIR" -maxdepth 1 -name 'manifest.*.bak' 2>/dev/null | sort)

    # Remove the manifest dir if nothing else lives there.  Under --dry-run
    # nothing was actually deleted, so rmdir would fail on a non-empty dir —
    # only attempt it for real runs.
    if ! $DRY_RUN && [[ -d "$MANIFEST_DIR" ]]; then
        rmdir "$MANIFEST_DIR" 2>/dev/null || true
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
    if $RESTORE_ONLY; then
        echo -e "\n${BOLD}${GREEN}Restore complete.${RESET}"
        echo
        echo "  Your install was left in place; only the backed-up files were"
        echo "  restored. Open a new terminal to apply them."
        return 0
    fi

    echo -e "\n${BOLD}${GREEN}Uninstall complete.${RESET}"
    echo
    if $RESTORE; then
        echo "  Your previous config has been restored."
        echo "  Open a new terminal to apply it."
    else
        echo "  Symlinks removed. Your shell will use the system defaults"
        echo "  until you restore a backup or run setup.sh again."
    fi
    # Only claim the tools are gone if the purge was actually carried out —
    # it can be declined at its own prompt.
    if $PURGED; then
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

    # The manifest tells us which backup belongs to the current install, so it
    # is read before the read-only backup commands too.
    read_manifest

    if $LIST_BACKUPS; then
        list_backups
        exit 0
    fi

    if [[ -n "$DELETE_BACKUP" ]]; then
        delete_backup "$DELETE_BACKUP"
        exit 0
    fi

    if $PRUNE_BACKUPS; then
        prune_backups
        exit 0
    fi

    # Resolve the backup BEFORE touching anything.  Validating inside
    # restore_backup meant a mistyped timestamp aborted the run after the
    # symlinks and .bashrc blocks were already gone.
    if $RESTORE; then
        resolve_backup_dir   # sets RESTORE_DIR, exits 1 if there is nothing to restore
    fi

    # Confirmation gate for non-dry-run runs.
    if ! $DRY_RUN; then
        echo -e "${YELLOW}This will:${RESET}"
        if $RESTORE_ONLY; then
            echo "  Restore every file from: ${RESTORE_DIR}"
            echo "  (existing files are snapshotted to ~/.bash_backup/<ts>-pre-restore first)"
        else
            if [[ ${#MANIFEST_LINKS[@]} -gt 0 ]]; then
                echo "  Remove the following managed symlinks:"
                local link
                for link in "${MANIFEST_LINKS[@]}"; do
                    echo "    $link"
                done
            fi
            if $RESTORE; then
                echo "  Restore every file from: ${RESTORE_DIR}"
            elif grep -qF "$BLOCK_HEAD_BEGIN" "${HOME}/.bashrc" 2>/dev/null \
                || grep -qF "$BLOCK_TAIL_BEGIN" "${HOME}/.bashrc" 2>/dev/null; then
                echo "  Remove bash-customizations blocks from ~/.bashrc"
            fi
            if $MANIFEST_GUARD_ADDED && ! $RESTORE; then
                echo "  Remove non-interactive guard added by setup.sh from ~/.bashrc"
            fi
        fi
        echo
        confirm "Proceed?" || { log_info "Aborted."; exit 0; }
        echo
    fi

    # --restore-only leaves the install alone; it exists so a wrong restore can
    # be corrected without uninstalling a second time.
    if $RESTORE_ONLY; then
        restore_backup
        if ! $DRY_RUN; then print_done; fi
        return 0
    fi

    remove_symlinks

    # When restoring, the backed-up ~/.bashrc replaces the current one wholesale,
    # so surgically stripping the managed blocks first is redundant — and doing
    # both is what used to leave ~/.bashrc unrestorable.
    if ! $RESTORE; then
        remove_bashrc_blocks
    fi

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
