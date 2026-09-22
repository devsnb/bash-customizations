#!/usr/bin/env bash
# setup.sh
#
# Idempotent setup script for the bash-customizations dotfile repo.
#
# What it does (in order):
#   1. Checks prerequisites (Bash ≥ 4.2; download tools only for a full install)
#   1.5. Ensures en_US.UTF-8 locale is installed (required by ble.sh)
#   2. Installs: starship · ble.sh · bash-completion · fd · fzf · zoxide
#   3. Deploys dotfiles (.bashrc · .bash/ · .blerc · starship.toml)
#      with automatic backup of any existing files/directories
#   4. Verifies that each tool is on PATH and prints a summary
#
# Usage:
#   bash setup.sh              # full install
#   bash setup.sh --dry-run    # show what would happen, change nothing
#   bash setup.sh --skip-tools # deploy dotfiles only (tools already installed)
#
# Re-running is safe — manifest-owned tools at the pinned version and
# already-deployed files are detected and skipped, unless --force is passed.
#
# Tool versions are read from tools.lock and verified by SHA256 before install.
# bash-completion is the exception: it comes from the system package manager.
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
XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
LOCAL_BIN="${HOME}/.local/bin"
CAPABILITY_CACHE_DIR="${XDG_CACHE_HOME}/bash-customizations"
CAPABILITY_CACHE_FILE="${CAPABILITY_CACHE_DIR}/capabilities.sh"

# Manifest — records every symlink we create so uninstall.sh knows exactly
# what to clean up.  One file, human-readable key=value format.
MANIFEST_DIR="${HOME}/.local/share/bash-customizations"
MANIFEST_FILE="${MANIFEST_DIR}/manifest"

# Block markers injected into ~/.bashrc (setup never symlinks ~/.bashrc)
BLOCK_HEAD_BEGIN="# === BEGIN bash-customizations ==="
BLOCK_HEAD_END="# === END bash-customizations ==="
BLOCK_TAIL_BEGIN="# === BEGIN bash-customizations-attach ==="
BLOCK_TAIL_END="# === END bash-customizations-attach ==="

# Runtime tracking (populated by deploy_file / _ensure_noninteractive_guard and
# the tool installers).  TOOL records hold name, version and installed-file
# hash; they are the ownership boundary used by uninstall.sh --purge-tools.
DEPLOYED_LINKS=()
PREVIOUS_MANAGED_TOOLS=()
MANAGED_TOOLS=()
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
if [[ ! -f "${REPO_DIR}/lib/log.sh" || ! -f "${REPO_DIR}/lib/version.sh" \
   || ! -f "${REPO_DIR}/lib/tools.sh" ]]; then
    echo "setup.sh: required files are missing from ${REPO_DIR}" >&2
    echo "          Expected lib/log.sh, lib/version.sh and lib/tools.sh." >&2
    echo "          The repository looks incomplete — re-clone it and try again." >&2
    exit 1
fi
# shellcheck source=lib/log.sh
source "${REPO_DIR}/lib/log.sh"
# shellcheck source=lib/version.sh
source "${REPO_DIR}/lib/version.sh"
# shellcheck source=lib/tools.sh
source "${REPO_DIR}/lib/tools.sh"

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

# fetch_verified TOOL PLATFORM VERSION DEST — download a pinned asset, or fail.
#
# The whole point of tools.lock: nothing reaches ~/.local/bin without matching a
# hash committed to this repo.  A mismatch is fatal and the partial file is
# removed — "it downloaded something, close enough" is how a corrupted binary
# or a swapped release becomes your login shell.
#
fetch_verified() {
    local tool="$1" platform="$2" version="$3" dest="$4"
    local url want got

    url="$(bc_tool_url "$tool" "$platform" "$version")" || {
        log_error "${tool}: no download URL for platform '${platform}'."
        return 1
    }

    if ! download "$url" > "$dest"; then
        log_error "${tool}: download failed — ${url}"
        rm -f "$dest"
        return 1
    fi

    want="$(bc_tool_sha "$tool" "$platform")" || {
        log_error "${tool}: tools.lock has no SHA256 for ${platform}."
        log_error "  Add it with:  bash tools/lock-tools.sh ${tool}"
        rm -f "$dest"
        return 1
    }
    got="$(bc_sha256 "$dest")" || {
        log_error "Cannot compute SHA256 — need sha256sum (coreutils) or shasum."
        rm -f "$dest"
        return 1
    }
    if [[ "$got" != "$want" ]]; then
        log_error "${tool}: CHECKSUM MISMATCH — refusing to install."
        log_error "  url      ${url}"
        log_error "  expected ${want}"
        log_error "  received ${got}"
        log_error "  Either the release was re-published or the download was tampered with."
        rm -f "$dest"
        return 1
    fi
    log_ok "${tool}: sha256 verified (${got:0:16}…)"
}

# tool_version TOOL — the version pinned in tools.lock.
tool_version() {
    bc_tool_version "$1"
}

# load_tool_ownership — retain TOOL=name:version records from the previous
# manifest.  Dotfile-only re-runs must not accidentally forget who owns the
# binaries, and upgrades need the old version to decide whether replacement is
# safe without --force.
load_tool_ownership() {
    local value
    [[ -r "$MANIFEST_FILE" ]] || return 0
    while IFS= read -r value; do
        value="${value#TOOL=}"
        [[ "$value" =~ ^(starship|fd|fzf|zoxide|blesh):[^:]+:[0-9a-f]{64}$ ]] || continue
        case "${value%%:*}" in
            starship|fd|fzf|zoxide|blesh) PREVIOUS_MANAGED_TOOLS+=("$value") ;;
        esac
    done < <(grep '^TOOL=' "$MANIFEST_FILE" 2>/dev/null || true)

    if $SKIP_TOOLS; then
        MANAGED_TOOLS=("${PREVIOUS_MANAGED_TOOLS[@]+"${PREVIOUS_MANAGED_TOOLS[@]}"}")
    fi
}

managed_tool_version() {
    local name="$1" record value
    for record in "${PREVIOUS_MANAGED_TOOLS[@]+"${PREVIOUS_MANAGED_TOOLS[@]}"}"; do
        [[ "${record%%:*}" == "$name" ]] || continue
        value="${record#*:}"
        printf '%s\n' "${value%%:*}"
        return 0
    done
    return 1
}

managed_tool_sha() {
    local name="$1" record value
    for record in "${PREVIOUS_MANAGED_TOOLS[@]+"${PREVIOUS_MANAGED_TOOLS[@]}"}"; do
        [[ "${record%%:*}" == "$name" ]] || continue
        value="${record#*:}"
        [[ "$value" == *:* ]] || return 1
        printf '%s\n' "${value#*:}"
        return 0
    done
    return 1
}

record_managed_tool() {
    local name="$1" version="$2" sha="$3" record
    for record in "${MANAGED_TOOLS[@]+"${MANAGED_TOOLS[@]}"}"; do
        [[ "${record%%:*}" == "$name" ]] && return 0
    done
    MANAGED_TOOLS+=("${name}:${version}:${sha}")
}

# write_tool_ownership_checkpoint — persist activated tools before continuing.
#
# Tool activation happens before dotfile deployment and the final manifest
# rewrite.  If a later download or ~/.bashrc update fails, an in-memory-only
# ownership record would be lost and the next run would reject our new binaries
# as unowned conflicts.  Update only TOOL= lines here; existing LINK/BACKUP data
# stays intact until write_manifest commits the completed install.
write_tool_ownership_checkpoint() {
    $DRY_RUN && return 0
    [[ ${#MANAGED_TOOLS[@]} -gt 0 ]] || return 0

    mkdir -p "$MANIFEST_DIR"
    local tmp line value name record managed
    tmp="$(mktemp "${MANIFEST_DIR}/.manifest.XXXXXX")"

    if [[ -f "$MANIFEST_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == TOOL=* ]]; then
                value="${line#TOOL=}"
                name="${value%%:*}"
                managed=false
                for record in "${MANAGED_TOOLS[@]}"; do
                    [[ "${record%%:*}" == "$name" ]] && { managed=true; break; }
                done
                $managed && continue
            fi
            printf '%s\n' "$line"
        done < "$MANIFEST_FILE" > "$tmp"
    else
        {
            printf '%s\n' '# bash-customizations in-progress ownership manifest'
            printf 'REPO=%s\n' "$REPO_DIR"
            printf 'VERSION=%s\n' "$BC_VERSION"
            printf 'BACKUP=\n'
        } > "$tmp"
    fi

    for record in "${MANAGED_TOOLS[@]}"; do
        printf 'TOOL=%s\n' "$record" >> "$tmp"
    done
    chmod 644 "$tmp"
    mv "$tmp" "$MANIFEST_FILE"
}

# installed_binary_version NAME — normalise the first dotted version printed by
# a local managed binary.  It deliberately addresses LOCAL_BIN directly: a
# system binary elsewhere on PATH must not suppress installation of the pin.
installed_binary_version() {
    local name="$1" output
    [[ -x "${LOCAL_BIN}/${name}" ]] || return 1
    output="$("${LOCAL_BIN}/${name}" --version 2>/dev/null | head -1)" || return 1
    printf '%s\n' "$output" | grep -oE 'v?[0-9]+([.][0-9]+)+' | head -1 | sed 's/^v//'
}

# binary_install_decision NAME VERSION
#   0 = install/upgrade, 1 = already pinned (skip), 2 = unowned conflict.
binary_install_decision() {
    local name="$1" version="$2" target="${LOCAL_BIN}/${1}" found="" found_sha=""
    local owned_version="" owned_sha=""
    owned_version="$(managed_tool_version "$name" 2>/dev/null || true)"
    owned_sha="$(managed_tool_sha "$name" 2>/dev/null || true)"

    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return 0
    fi
    if [[ -d "$target" && ! -L "$target" ]]; then
        log_error "${target} is a directory; refusing to replace it with an executable."
        return 2
    fi
    if $FORCE; then
        return 0
    fi

    found="$(installed_binary_version "$name" 2>/dev/null || true)"
    found_sha="$(bc_sha256 "$target" 2>/dev/null || true)"
    if [[ "$found" == "$version" && "$owned_version" == "$version" \
        && -n "$owned_sha" && "$found_sha" == "$owned_sha" ]]; then
        record_managed_tool "$name" "$version" "$found_sha"
        log_ok "${name} ${version} already installed at ${target}"
        return 1
    fi
    if [[ -n "$owned_version" ]]; then
        return 0
    fi

    log_error "${target} already exists and is not owned by bash-customizations."
    log_error "  Found version: ${found:-unknown}; pinned version: ${version}"
    log_error "  Move it aside, or use --force to replace it and record ownership."
    return 2
}

# install_verified_binary NAME VERSION PLATFORM — stage, validate, then rename
# the binary into place.  Extraction never writes through the live path, so a
# corrupt archive or failed validation leaves the previous executable intact.
install_verified_binary() {
    local name="$1" version="$2" platform="$3"
    local blob stage staged found previous_link="" archive_member="$name"
    mkdir -p "$LOCAL_BIN"
    blob="$(mktemp)"
    stage="$(mktemp -d "${LOCAL_BIN}/.${name}.install.XXXXXX")"

    # fd's release archives wrap the executable in a versioned directory;
    # the other managed binary archives put it at their root.
    if [[ "$name" == fd ]]; then
        archive_member="fd-v${version}-$(_bc_tool_triple fd "$platform")/fd"
    fi

    if ! fetch_verified "$name" "$platform" "$version" "$blob" \
        || ! tar -xzf "$blob" -C "$stage" "$archive_member"; then
        log_error "${name}: could not download or unpack the verified archive"
        rm -rf "$blob" "$stage"
        return 1
    fi

    staged="${stage}/${archive_member}"
    chmod +x "$staged"
    found="$("$staged" --version 2>/dev/null | head -1 \
        | grep -oE 'v?[0-9]+([.][0-9]+)+' | head -1 | sed 's/^v//' || true)"
    if [[ "$found" != "$version" ]]; then
        log_error "${name}: staged binary reports ${found:-no version}, expected ${version}"
        rm -rf "$blob" "$stage"
        return 1
    fi

    # mv can interpret a symlink-to-directory as a directory destination on
    # some systems.  Rename the link aside first and restore it on failure.
    if [[ -L "${LOCAL_BIN}/${name}" ]]; then
        previous_link="${stage}/previous-link"
        if ! mv "${LOCAL_BIN}/${name}" "$previous_link"; then
            log_error "${name}: could not stage the previous symlink"
            rm -rf "$blob" "$stage"
            return 1
        fi
    fi
    if ! mv -f "$staged" "${LOCAL_BIN}/${name}"; then
        log_error "${name}: could not replace ${LOCAL_BIN}/${name}"
        [[ -n "$previous_link" ]] && mv "$previous_link" "${LOCAL_BIN}/${name}" 2>/dev/null || true
        rm -rf "$blob" "$stage"
        return 1
    fi
    rm -rf "$blob" "$stage"
    found="$(bc_sha256 "${LOCAL_BIN}/${name}")"
    record_managed_tool "$name" "$version" "$found"
    log_ok "${name} installed: $("${LOCAL_BIN}/${name}" --version 2>/dev/null | head -1)"
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
            -V|--version) print_version "setup.sh"; exit 0 ;;
            -h|--help)
                echo "Usage: bash setup.sh [--dry-run] [--skip-tools] [--force]"
                echo
                echo "  --dry-run     Show what would happen without making changes"
                echo "  --skip-tools  Deploy dotfiles only, skip tool installation"
                echo "  --force       Replace local tools and record project ownership"
                echo "  -V, --version Print the version and exit"
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

    # The configuration and verified binary matrix deliberately support Linux
    # on 64-bit x86 and ARM only. Reject other systems even for --skip-tools so
    # a partial dotfile deployment cannot be mistaken for platform support.
    local platform
    if ! platform="$(bc_tool_platform)"; then
        log_error "Unsupported platform: $(uname -s)/$(uname -m)."
        log_error "Only Linux x86_64 (x64) and aarch64 (ARM64) are supported."
        exit 1
    fi
    log_ok "Platform ${platform}"

    # Bash version ≥ 4.2
    local bash_major="${BASH_VERSINFO[0]}" bash_minor="${BASH_VERSINFO[1]}"
    if (( bash_major < 4 || ( bash_major == 4 && bash_minor < 2 ) )); then
        log_error "Bash 4.2+ required (found ${BASH_VERSION})."
        log_error "Install Bash 4.2 or newer with your Linux package manager."
        exit 1
    fi
    log_ok "Bash ${BASH_VERSION}"

    # Dotfile deployment needs only Bash and the ordinary core utilities used
    # to create links and rewrite ~/.bashrc.  In particular, --skip-tools is the
    # recovery path when tools.lock or a downloader/unpacker is unavailable.
    if $SKIP_TOOLS; then
        return 0
    fi

    if ! bc_tools_validate; then
        log_error "tools.lock is incomplete or malformed; refusing to download tools."
        log_error "  Restore it from git or regenerate it with: make tools-update"
        exit 1
    fi
    if ! bc_sha256 /dev/null >/dev/null 2>&1; then
        log_error "sha256sum or shasum is required to verify downloaded and installed tools."
        exit 1
    fi

    # curl or wget
    if ! has curl && ! has wget; then
        log_error "curl or wget is required for downloading tools."
        exit 1
    fi
    if has curl; then log_ok "curl $(curl --version 2>/dev/null | head -1)"; fi
    if has wget; then log_ok "wget $(wget --version 2>/dev/null | head -1)"; fi

    # git is useful for updating this checkout, but tool installation no longer
    # depends on it: every user-local binary comes from a pinned release asset.
    if ! has git; then
        log_warn "git not found — setup works, but 'make update' will not."
    else
        log_ok "git $(git --version)"
    fi

    # tar + gzip + xz unpack the verified release archives.
    # Without these the failure surfaces late and cryptically, mid-download.
    if ! has tar; then
        log_error "tar is required to unpack ble.sh."
        exit 1
    fi
    log_ok "tar $(tar --version 2>/dev/null | head -1)"
    if ! has gzip; then
        log_error "gzip is required to unpack starship, fd, fzf and zoxide."
        exit 1
    fi
    if ! has xz; then
        log_error "xz is required to unpack ble.sh (.tar.xz)."
        log_error "  Debian/Ubuntu: sudo apt-get install -y xz-utils"
        exit 1
    fi

    # Say up front that some steps need root, rather than surprising the user
    # with a password prompt halfway through the run.
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root — package installs will not use sudo."
    elif has sudo; then
        log_info "Some optional steps (bash-completion, locale) may ask for your sudo password."
    else
        log_warn "No sudo available — package installs and locale generation will be skipped."
        log_warn "Everything installed into ~/.local/bin works without root."
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
    local version; version="$(tool_version starship)" || {
        log_error "starship: no version available (tools.lock unreadable?)"; return 1; }
    log_section "Starship ${version}"

    local decision=0
    binary_install_decision starship "$version" || decision=$?
    [[ "$decision" -eq 1 ]] && return 0
    [[ "$decision" -eq 2 ]] && return 1

    local platform; platform="$(bc_tool_platform)" || {
        log_error "starship: unsupported platform $(uname -s)/$(uname -m)"
        log_error "  Install it manually: https://starship.rs/guide/#installation"
        return 1
    }

    if $DRY_RUN; then
        log_dry "download $(bc_tool_url starship "$platform" "$version")"
        log_dry "verify sha256, then extract 'starship' into ${LOCAL_BIN}"
        return 0
    fi

    log_info "Installing Starship ${version} to ${LOCAL_BIN}…"
    install_verified_binary starship "$version" "$platform"
}

# ── ble.sh ────────────────────────────────────────────────────────────────────
install_blesh() {
    local version; version="$(tool_version blesh)" || {
        log_error "ble.sh: no version available (tools.lock unreadable?)"; return 1; }
    log_section "ble.sh ${version}"

    local blesh_dir="${XDG_DATA_HOME}/blesh"

    local owned_version="" owned_sha="" installed_sha="" installed_output="" commit=""
    owned_version="$(managed_tool_version blesh 2>/dev/null || true)"
    owned_sha="$(managed_tool_sha blesh 2>/dev/null || true)"
    commit="${version##*+}"
    if [[ -f "${blesh_dir}/ble.sh" ]] && ! $FORCE; then
        installed_output="$(bash "${blesh_dir}/ble.sh" --version 2>/dev/null | head -1 || true)"
        installed_sha="$(bc_sha256 "${blesh_dir}/ble.sh" 2>/dev/null || true)"
        if [[ "$owned_version" == "$version" && "$installed_output" == *"+${commit}"* \
            && -n "$owned_sha" && "$installed_sha" == "$owned_sha" ]]; then
            record_managed_tool blesh "$version" "$installed_sha"
            log_ok "ble.sh ${version} already installed at ${blesh_dir}"
            return 0
        fi
        if [[ -z "$owned_version" ]]; then
            log_error "${blesh_dir} already exists and is not owned by bash-customizations."
            log_error "  Move it aside, or use --force to replace it and record ownership."
            return 1
        fi
    fi

    if $DRY_RUN; then
        log_dry "download $(bc_tool_url blesh any "$version")"
        log_dry "verify sha256, then: bash ble.sh --install ${XDG_DATA_HOME}"
        return 0
    fi

    log_info "Installing ble.sh ${version} to ${blesh_dir}…"

    mkdir -p "$XDG_DATA_HOME"
    local blob tmp_dir install_root staged_dir previous_dir staged_output
    blob="$(mktemp)"
    tmp_dir="$(mktemp -d)"
    install_root="$(mktemp -d "${XDG_DATA_HOME}/.blesh.install.XXXXXX")"
    staged_dir="${install_root}/blesh"
    previous_dir="$(mktemp -d "${XDG_DATA_HOME}/.blesh.previous.XXXXXX")"
    rmdir "$previous_dir"
    # Inline cleanup rather than a RETURN trap: bash's set -e bypasses RETURN
    # traps (it fires ERR and exits the script outright, never returning).
    local blesh_ok=false
    if fetch_verified blesh any "$version" "$blob" \
        && tar -xJf "$blob" -C "$tmp_dir"; then
        # A dated nightly unpacks to ble-nightly-<date>+<sha>/, not ble-nightly/,
        # so glob for the installer rather than assuming the directory name.
        local installer
        installer="$(find "$tmp_dir" -maxdepth 2 -name 'ble.sh' -type f | head -1)"
        if [[ -n "$installer" ]] && bash "$installer" --install "$install_root" \
            && [[ -f "${staged_dir}/ble.sh" ]]; then
            staged_output="$(bash "${staged_dir}/ble.sh" --version 2>/dev/null | head -1 || true)"
            if [[ "$staged_output" != *"+${commit}"* ]]; then
                log_error "ble.sh: staged install reports the wrong build: ${staged_output:-unknown}"
                rm -rf "$tmp_dir" "$install_root" "$blob"
                return 1
            fi
            if [[ -d "$blesh_dir" || -L "$blesh_dir" ]]; then
                if ! mv "$blesh_dir" "$previous_dir"; then
                    log_error "ble.sh: could not stage the previous installation"
                elif mv "$staged_dir" "$blesh_dir"; then
                    rm -rf "$previous_dir"
                    blesh_ok=true
                else
                    log_error "ble.sh: could not activate the staged installation; restoring previous version"
                    mv "$previous_dir" "$blesh_dir" 2>/dev/null || true
                fi
            elif mv "$staged_dir" "$blesh_dir"; then
                blesh_ok=true
            fi
        else
            log_error "ble.sh: archive did not produce a usable staged installation"
        fi
    fi
    rm -rf "$tmp_dir" "$install_root" "$blob"

    if $blesh_ok; then
        installed_sha="$(bc_sha256 "${blesh_dir}/ble.sh")"
        record_managed_tool blesh "$version" "$installed_sha"
        log_ok "ble.sh installed at ${blesh_dir}"
    else
        log_error "ble.sh installation failed (download, checksum or install step)"
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
    if ! root_available; then
        log_warn "Skipping bash-completion — needs root and no sudo is available."
        log_warn "Install it yourself later: <your package manager> install bash-completion"
        return 0
    fi

    log_info "Installing bash-completion via system package manager…"

    if $DRY_RUN; then
        if has apt-get;  then  log_dry "apt-get update && apt-get install -y bash-completion"
        elif has dnf;    then  log_dry "dnf install -y bash-completion"
        elif has pacman; then  log_dry "pacman -S --noconfirm bash-completion"
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

# ── fd ────────────────────────────────────────────────────────────────────────
install_fd() {
    local version; version="$(tool_version fd)" || {
        log_error "fd: no version available (tools.lock unreadable?)"; return 1; }
    log_section "fd ${version}"

    local decision=0
    binary_install_decision fd "$version" || decision=$?
    [[ "$decision" -eq 1 ]] && return 0
    [[ "$decision" -eq 2 ]] && return 1

    local platform; platform="$(bc_tool_platform)" || {
        log_error "fd: unsupported platform $(uname -s)/$(uname -m)"
        log_error "  Install it manually: https://github.com/sharkdp/fd/releases"
        return 1
    }

    if $DRY_RUN; then
        log_dry "download $(bc_tool_url fd "$platform" "$version")"
        log_dry "verify sha256, then extract 'fd' into ${LOCAL_BIN}"
        return 0
    fi

    log_info "Installing fd ${version} to ${LOCAL_BIN}…"
    install_verified_binary fd "$version" "$platform"
}

# ── fzf ───────────────────────────────────────────────────────────────────────
install_fzf() {
    local version; version="$(tool_version fzf)" || {
        log_error "fzf: no version available (tools.lock unreadable?)"; return 1; }
    log_section "fzf ${version}"

    local decision=0
    binary_install_decision fzf "$version" || decision=$?
    [[ "$decision" -eq 1 ]] && return 0
    [[ "$decision" -eq 2 ]] && return 1

    local platform; platform="$(bc_tool_platform)" || {
        log_error "fzf: unsupported platform $(uname -s)/$(uname -m)"
        log_error "  Install it manually: https://github.com/junegunn/fzf/releases"
        return 1
    }

    if $DRY_RUN; then
        log_dry "download $(bc_tool_url fzf "$platform" "$version")"
        log_dry "verify sha256, then extract 'fzf' into ${LOCAL_BIN}"
        return 0
    fi

    # The git-clone path is gone: it tracked the tip of the default branch, so
    # two machines set up a week apart got different fzf builds, and there was
    # nothing to check a hash against.  The release tarball is one file, one
    # hash, and needs neither git nor a compiler.
    log_info "Installing fzf ${version} to ${LOCAL_BIN}…"
    install_verified_binary fzf "$version" "$platform"
}

# write_capability_cache — resolve startup-time feature checks once per setup.
#
# Negative command lookups are surprisingly expensive on WSL when PATH contains
# many /mnt/c entries.  The runtime modules source these booleans instead of
# searching PATH whenever a terminal opens.  Re-run setup.sh --skip-tools after
# manually installing or removing an optional companion such as eza or docker.
write_capability_cache() {
    if $DRY_RUN; then
        log_dry "refresh runtime capability cache: ${CAPABILITY_CACHE_FILE}"
        return 0
    fi

    mkdir -p "$CAPABILITY_CACHE_DIR"
    local tmp tool variable available
    tmp="$(mktemp "${CAPABILITY_CACHE_DIR}/.capabilities.XXXXXX")"
    {
        echo '# Generated by bash-customizations setup.sh; do not edit.'
        echo 'BC_CAP_CACHE_VERSION=1'
        for tool in fd rg eza docker fzf zoxide starship; do
            variable="BC_CAP_${tool^^}"
            available=0
            if [[ -x "${LOCAL_BIN}/${tool}" ]] || command -v "$tool" &>/dev/null; then
                available=1
            fi
            printf '%s=%s\n' "$variable" "$available"
        done
    } > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$CAPABILITY_CACHE_FILE"
    log_ok "Runtime capability cache refreshed: ${CAPABILITY_CACHE_FILE}"
}

# ── zoxide ────────────────────────────────────────────────────────────────────
install_zoxide() {
    local version; version="$(tool_version zoxide)" || {
        log_error "zoxide: no version available (tools.lock unreadable?)"; return 1; }
    log_section "zoxide ${version}"

    local decision=0
    binary_install_decision zoxide "$version" || decision=$?
    [[ "$decision" -eq 1 ]] && return 0
    [[ "$decision" -eq 2 ]] && return 1

    local platform; platform="$(bc_tool_platform)" || {
        log_error "zoxide: unsupported platform $(uname -s)/$(uname -m)"
        log_error "  Install it manually: https://github.com/ajeetdsouza/zoxide/releases"
        return 1
    }

    if $DRY_RUN; then
        log_dry "download $(bc_tool_url zoxide "$platform" "$version")"
        log_dry "verify sha256, then extract 'zoxide' into ${LOCAL_BIN}"
        return 0
    fi

    # This used to pipe install.sh from zoxide's **main branch** into sh — an
    # unreleased, unpinned, unverified script running as you.  The release
    # tarball carries the same binary.
    log_info "Installing zoxide ${version} to ${LOCAL_BIN}…"
    install_verified_binary zoxide "$version" "$platform"
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

# _valid_block_pair FILE BEGIN END — exactly one ordered, non-nested pair.
_valid_block_pair() {
    awk -v begin="$2" -v end="$3" '
        $0 == begin { begins++; if (inside) bad = 1; inside = 1; next }
        $0 == end   { ends++;   if (!inside) bad = 1; inside = 0 }
        END { exit !(begins == 1 && ends == 1 && !inside && !bad) }
    ' "$1" 2>/dev/null
}

# _rewrite_block FILE BEGIN END NEW_BLOCK_FILE
# Replace the old block (between BEGIN and END inclusive) with NEW_BLOCK_FILE.
# NEW_BLOCK_FILE must include the begin/end marker lines.
_rewrite_block() {
    local file="$1" begin="$2" end="$3" new_block_file="$4"
    if ! _valid_block_pair "$file" "$begin" "$end"; then
        log_error "Malformed managed block in ${file} — refusing to rewrite it."
        log_error "Expected exactly one ordered BEGIN/END marker pair."
        return 1
    fi
    local tmp
    tmp="$(mktemp "${file}.bash-customizations.XXXXXX")"
    local in_block=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$begin" ]]; then
            cat "$new_block_file"
            in_block=1
        elif [[ $in_block -eq 1 && "$line" == "$end" ]]; then
            in_block=0
        elif [[ $in_block -eq 0 ]]; then
            printf '%s\n' "$line"
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
    tmp="$(mktemp "${file}.bash-customizations.XXXXXX")"
    local inserted_head=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        if [[ $inserted_head -eq 0 && "$line" == *'$-'*'*i*'*'return'* ]]; then
            printf '\n'
            cat "$head_file"
            printf '\n'
            inserted_head=1
        fi
    done < "$file" > "$tmp"

    if [[ $inserted_head -eq 0 ]]; then
        # No non-interactive guard found — prepend HEAD block
        local tmp2
        tmp2="$(mktemp "${file}.bash-customizations.XXXXXX")"
        { cat "$head_file"; printf '\n'; cat "$tmp"; } > "$tmp2"
        mv "$tmp2" "$tmp"
    fi

    # Append TAIL block
    { cat "$tmp"; printf '\n'; cat "$tail_file"; } > "${tmp}.out"
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
    tmp="$(mktemp "${file}.bash-customizations.XXXXXX")"
    local inserted=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $inserted -eq 0 && "$line" == "$BLOCK_HEAD_BEGIN" ]]; then
            printf '%s\n\n' "$guard"
            inserted=1
        fi
        printf '%s\n' "$line"
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

    # Validate every marker pair before changing either block.  This prevents a
    # valid HEAD from being updated before a malformed TAIL is discovered, and
    # ensures a damaged marker can never make a rewrite consume user content.
    if grep -qF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null \
        && ! _valid_block_pair "$bashrc" "$BLOCK_HEAD_BEGIN" "$BLOCK_HEAD_END"; then
        log_error "Malformed bash-customizations HEAD block in ${bashrc} — refusing to rewrite it."
        return 1
    fi
    if grep -qF "$BLOCK_TAIL_BEGIN" "$bashrc" 2>/dev/null \
        && ! _valid_block_pair "$bashrc" "$BLOCK_TAIL_BEGIN" "$BLOCK_TAIL_END"; then
        log_error "Malformed bash-customizations TAIL block in ${bashrc} — refusing to rewrite it."
        return 1
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
        # Which release deployed these files.  doctor.sh compares it against
        # the repo's VERSION so a machine can say what it is running.
        echo "VERSION=${BC_VERSION}"
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
        # Ownership, not mere presence, authorises uninstall.sh --purge-tools.
        # Versions and hashes make upgrades auditable and let setup distinguish
        # its own intact install from an unrelated or modified binary.
        local tool_record
        for tool_record in "${MANAGED_TOOLS[@]+"${MANAGED_TOOLS[@]}"}"; do
            echo "TOOL=${tool_record}"
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

    if ! $SKIP_TOOLS; then
        _check "starship"       starship
        _check "fd"             fd
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

        # bash-completion lives in system paths and needs root to install, so
        # its absence is advisory rather than a failure.
        if [[ -f /usr/share/bash-completion/bash_completion ]] \
            || [[ -f /usr/local/share/bash-completion/bash_completion ]]; then
            log_ok "bash-completion: found"
        else
            log_warn "bash-completion: not found (needs root to install — optional)"
            (( advisories++ )) || true
        fi
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
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
    print_banner
    load_tool_ownership
    check_prerequisites
    $SKIP_TOOLS || ensure_locale

    if ! $SKIP_TOOLS; then
        install_starship
        write_tool_ownership_checkpoint
        install_blesh
        write_tool_ownership_checkpoint
        install_bash_completion
        install_fd
        write_tool_ownership_checkpoint
        install_fzf
        write_tool_ownership_checkpoint
        install_zoxide
        write_tool_ownership_checkpoint
    fi

    write_capability_cache

    deploy_dotfiles

    # verify() returns non-zero when something is off; don't hide that behind a
    # green "Setup complete!" banner.
    local verified=true
    verify || verified=false

    if ! $DRY_RUN; then print_done "$verified"; fi
    $verified
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
