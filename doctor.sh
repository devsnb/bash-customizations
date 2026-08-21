#!/usr/bin/env bash
# doctor.sh
#
# Diagnose the bash-customizations setup and report exactly what's wrong
# with actionable instructions to fix each issue.
#
# Checks performed:
#   1.  Bash version (≥ 4.2 required)
#   2.  PATH contains ~/.local/bin
#   3.  Tool binaries: starship, fzf, zoxide
#   4.  ble.sh installation
#   5.  bash-completion availability
#   6.  Manifest exists and is readable
#   7.  Every managed symlink: exists, is a symlink, points into the repo,
#       and the repo source file is present (not dangling)
#   8.  .bashrc structure:
#         - ble.sh --attach=none appears before any module source lines
#         - all module source lines are present
#         - ble-attach appears after prompt.sh source
#         - no conflicting fzf --bash eval when ble.sh is present
#   9.  .blerc: exists and contains fzf integration
#  10.  starship.toml: exists at the expected location
#  11.  History file: exists and is writable
#  12.  ble.sh + fzf conflict detection
#
# Exit codes:
#   0  — all checks passed (healthy)
#   1  — one or more checks failed (issues found)
#
# Usage:
#   bash doctor.sh           # full check
#   bash doctor.sh --quiet   # only print failures, not passes
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
LOCAL_BIN="${HOME}/.local/bin"
MANIFEST_FILE="${HOME}/.local/share/bash-customizations/manifest"

# Block markers (must match setup.sh)
BLOCK_HEAD_BEGIN="# === BEGIN bash-customizations ==="
BLOCK_HEAD_END="# === END bash-customizations ==="
BLOCK_TAIL_BEGIN="# === BEGIN bash-customizations-attach ==="
BLOCK_TAIL_END="# === END bash-customizations-attach ==="

QUIET=false          # set by --quiet flag
ISSUES=0             # incremented for every FAIL or WARN

# ══════════════════════════════════════════════════════════════════════════════
# Colours & output helpers
# ══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# pass MESSAGE — a check that passed.
pass() {
    if $QUIET; then return 0; fi
    echo -e "  ${GREEN}✔${RESET}  $*"
}

# fail MESSAGE FIX — a check that failed.  FIX is printed as a suggestion.
fail() {
    local msg="$1" fix="${2:-}"
    echo -e "  ${RED}✘${RESET}  ${BOLD}${msg}${RESET}"
    if [[ -n "$fix" ]]; then echo -e "       ${YELLOW}→ Fix:${RESET} ${fix}"; fi
    (( ISSUES++ )) || true
}

# warn MESSAGE SUGGESTION
warn() {
    local msg="$1" suggestion="${2:-}"
    echo -e "  ${YELLOW}!${RESET}  ${msg}"
    if [[ -n "$suggestion" ]]; then echo -e "       ${YELLOW}→ Tip:${RESET} ${suggestion}"; fi
    (( ISSUES++ )) || true
}

# info MESSAGE — informational, never counts as an issue.
info() {
    if $QUIET; then return 0; fi
    echo -e "  ${BLUE}i${RESET}  $*"
}

# ══════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ══════════════════════════════════════════════════════════════════════════════

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --quiet|-q) QUIET=true ;;
            -h|--help)
                echo "Usage: bash doctor.sh [--quiet]"
                echo
                echo "Options:"
                echo "  --quiet   Only print failures and warnings (suppress passing checks)"
                echo
                echo "Exit codes: 0 = healthy, 1 = one or more issues found"
                echo
                echo "Checks performed:"
                echo "   1  Bash version ≥ 4.2"
                echo "   2  ~/.local/bin on PATH"
                echo "   3  starship / fzf / zoxide binaries present and functional"
                echo "   4  ble.sh installed"
                echo "   5  bash-completion available"
                echo "   6  Install manifest exists and matches this repo"
                echo "   7  All managed symlinks valid (not dangling, point into repo)"
                echo "   8  .bashrc structure: load order, all modules sourced, ble-attach last"
                echo "   9  .blerc contains fzf integration blocks"
                echo "  10  starship.toml exists and is well-formed"
                echo "  11  History file writable"
                echo "  12  No fzf --bash conflict alongside ble.sh"
                echo
                echo "Examples:"
                echo "  bash doctor.sh                # full check, show all results"
                echo "  bash doctor.sh --quiet        # show only failures"
                echo "  bash doctor.sh; echo \$?       # use exit code in a script (0=ok, 1=issues)"
                exit 0
                ;;
            *)
                echo "Unknown argument: $arg  (use --help)" >&2
                exit 1
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: Bash version
# ══════════════════════════════════════════════════════════════════════════════

check_bash_version() {
    log_section "Bash version"

    local major="${BASH_VERSINFO[0]}" minor="${BASH_VERSINFO[1]}"

    if (( major < 4 || ( major == 4 && minor < 2 ) )); then
        fail "Bash ${BASH_VERSION} — version 4.2+ required" \
             "macOS: brew install bash && chsh -s \$(brew --prefix)/bin/bash"
    else
        pass "Bash ${BASH_VERSION}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: PATH
# ══════════════════════════════════════════════════════════════════════════════

check_path() {
    log_section "PATH"

    if [[ ":${PATH}:" == *":${LOCAL_BIN}:"* ]]; then
        pass "~/.local/bin is on PATH"
    else
        fail "~/.local/bin is NOT on PATH" \
             "exports.sh adds it — open a new terminal or: source ~/.bash/exports.sh"
    fi

    # Check whether ~/.local/bin actually has our binaries
    for bin in starship fzf zoxide; do
        if [[ -f "${LOCAL_BIN}/${bin}" ]]; then
            pass "${LOCAL_BIN}/${bin} exists"
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: Tool binaries
# ══════════════════════════════════════════════════════════════════════════════

check_tools() {
    log_section "Tool binaries"

    # starship
    if command -v starship &>/dev/null; then
        pass "starship: $(starship --version 2>/dev/null | head -1)"
    else
        fail "starship not found on PATH" \
             "bash setup.sh  (or: curl -sS https://starship.rs/install.sh | sh)"
    fi

    # fzf
    if command -v fzf &>/dev/null; then
        local fzf_ver
        fzf_ver="$(fzf --version 2>/dev/null | head -1)"
        pass "fzf: ${fzf_ver}"
        # Check for minimum version (0.48.0 required for fzf --bash)
        # Parse version with POSIX tools (grep -P is GNU-only, absent on macOS).
        local fzf_major fzf_minor
        fzf_major="$(echo "$fzf_ver" | grep -oE '[0-9]+' | awk 'NR==1')" || fzf_major=0
        fzf_minor="$(echo "$fzf_ver" | grep -oE '[0-9]+' | awk 'NR==2')" || fzf_minor=0
        fzf_major="${fzf_major:-0}"
        fzf_minor="${fzf_minor:-0}"
        if (( fzf_major == 0 && fzf_minor < 48 )); then
            warn "fzf version ${fzf_ver} is older than 0.48.0 (fzf --bash not supported)" \
                 "Update: git -C ~/.fzf pull && ~/.fzf/install --all --no-bash --no-zsh --no-fish"
        fi
    else
        fail "fzf not found on PATH" \
             "bash setup.sh  (or: git clone https://github.com/junegunn/fzf ~/.fzf && ~/.fzf/install)"
    fi

    # zoxide
    if command -v zoxide &>/dev/null; then
        pass "zoxide: $(zoxide --version 2>/dev/null | head -1)"
    else
        fail "zoxide not found on PATH" \
             "bash setup.sh  (or: curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh)"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: ble.sh
# ══════════════════════════════════════════════════════════════════════════════

check_blesh() {
    log_section "ble.sh"

    local blesh_file="${XDG_DATA_HOME}/blesh/ble.sh"

    if [[ -f "$blesh_file" ]]; then
        pass "ble.sh installed: ${blesh_file}"
    else
        fail "ble.sh not found at ${blesh_file}" \
             "bash setup.sh  (or: curl -L https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz | tar xJf - && bash ble-nightly/ble.sh --install ~/.local/share)"
    fi

    # Check .blerc
    if [[ -f "${HOME}/.blerc" ]]; then
        pass ".blerc exists"
        # Check for fzf integration lines
        if grep -q 'fzf-key-bindings' "${HOME}/.blerc" 2>/dev/null; then
            pass ".blerc has fzf key-bindings integration"
        else
            warn ".blerc is missing fzf-key-bindings integration" \
                 "Add: ble-import -d integration/fzf-key-bindings  to ~/.blerc"
        fi
        if grep -q 'fzf-completion' "${HOME}/.blerc" 2>/dev/null; then
            pass ".blerc has fzf completion integration"
        else
            warn ".blerc is missing fzf completion integration" \
                 "Add: ble-import -d integration/fzf-completion  to ~/.blerc"
        fi
    elif [[ -L "${HOME}/.blerc" ]]; then
        fail ".blerc is a dangling symlink" \
             "bash setup.sh --skip-tools  (re-deploy dotfiles)"
    else
        fail ".blerc does not exist" \
             "bash setup.sh --skip-tools  (deploy dotfiles)"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: bash-completion
# ══════════════════════════════════════════════════════════════════════════════

check_bash_completion() {
    log_section "bash-completion"

    local found_at="" path
    for path in \
        /usr/share/bash-completion/bash_completion \
        /usr/local/share/bash-completion/bash_completion \
        /etc/bash_completion; do
        if [[ -f "$path" ]]; then
            found_at="$path"
            break
        fi
    done

    # Also check Homebrew on macOS
    if [[ -z "$found_at" && "$OSTYPE" == darwin* ]]; then
        local brew_prefix="${HOMEBREW_PREFIX:-}"
        if [[ -z "$brew_prefix" ]] && command -v brew &>/dev/null; then
            brew_prefix="$(brew --prefix)"
        fi
        for path in \
            "${brew_prefix}/etc/profile.d/bash_completion.sh" \
            "${brew_prefix}/share/bash-completion/bash_completion"; do
            if [[ -f "$path" ]]; then
                found_at="$path"
                break
            fi
        done
    fi

    if [[ -n "$found_at" ]]; then
        pass "bash-completion found: ${found_at}"
    else
        fail "bash-completion not found" \
             "Install with your package manager: sudo apt install bash-completion  /  brew install bash-completion@2"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: Manifest
# ══════════════════════════════════════════════════════════════════════════════

check_manifest() {
    log_section "Install manifest"

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "Manifest not found at ${MANIFEST_FILE}" \
             "Run bash setup.sh to create it (needed by uninstall.sh)"
        return
    fi

    pass "Manifest exists: ${MANIFEST_FILE}"

    local link_count
    # Use grep|wc -l (not grep -c) because grep -c exits 1 for zero matches,
    # and "|| echo 0" would then produce "0\n0" (grep's own output + echo's).
    link_count="$(grep '^LINK=' "$MANIFEST_FILE" 2>/dev/null | wc -l | tr -d ' ')"
    info "${link_count} symlink(s) recorded in manifest"

    local repo_in_manifest
    repo_in_manifest="$(grep '^REPO=' "$MANIFEST_FILE" 2>/dev/null | cut -d= -f2 || true)"
    if [[ -n "$repo_in_manifest" && "$repo_in_manifest" != "$REPO_DIR" ]]; then
        warn "Manifest REPO (${repo_in_manifest}) does not match current script location (${REPO_DIR})" \
             "If you moved the repo, run: bash setup.sh --skip-tools  to update the manifest"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: Symlinks
# ══════════════════════════════════════════════════════════════════════════════

check_symlinks() {
    log_section "Managed symlinks"

    # Determine expected links (from manifest or defaults)
    local links=()
    if [[ -f "$MANIFEST_FILE" ]]; then
        while IFS='=' read -r key value; do
                if [[ "$key" == "LINK" ]]; then links+=("$value"); fi
            done < "$MANIFEST_FILE"
    else
        # Fallback to the known list
        links=(
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
    fi

    if [[ ${#links[@]} -eq 0 ]]; then
        warn "No symlinks recorded in manifest" \
             "Run bash setup.sh --skip-tools to deploy dotfiles"
        return
    fi

    for link in "${links[@]}"; do
        if [[ ! -e "$link" && ! -L "$link" ]]; then
            fail "${link} — missing entirely" \
                 "bash setup.sh --skip-tools  (re-deploy dotfiles)"
            continue
        fi

        if [[ ! -L "$link" ]]; then
            warn "${link} exists but is NOT a symlink (real file, possibly from before setup)" \
                 "Inspect manually; then: bash uninstall.sh && bash setup.sh"
            continue
        fi

        # Dangling symlink (target doesn't exist)
        if [[ ! -e "$link" ]]; then
            local dangling_target
            dangling_target="$(readlink "$link")"
            fail "${link} is a DANGLING symlink → ${dangling_target}" \
                 "bash setup.sh --skip-tools  (re-link; repo may have moved)"
            continue
        fi

        # Points somewhere unexpected
        local target
        target="$(readlink -f "$link" 2>/dev/null || true)"
        if [[ -z "$target" ]]; then
            warn "${link} — could not resolve symlink target (readlink -f unavailable?)" \
                 "On macOS install coreutils: brew install coreutils"
            continue
        fi
        if [[ "$target" != "${REPO_DIR}/"* ]]; then
            warn "${link} → ${target}  (does not point into repo at ${REPO_DIR})" \
                 "This file is not managed by us. Inspect manually."
            continue
        fi

        pass "${link} → ${target##"${REPO_DIR}/"}"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: .bashrc structure
# ══════════════════════════════════════════════════════════════════════════════

check_bashrc() {
    log_section ".bashrc structure"

    local bashrc="${HOME}/.bashrc"

    if [[ ! -f "$bashrc" ]]; then
        fail "~/.bashrc does not exist" \
             "bash setup.sh"
        return
    fi

    pass "~/.bashrc exists"

    # ── Managed blocks ────────────────────────────────────────────────────────
    local head_ok=true tail_ok=true

    if grep -qF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null; then
        pass "HEAD block present (ble.sh + module sources)"
    else
        fail "bash-customizations HEAD block missing from ~/.bashrc" \
             "bash setup.sh --skip-tools"
        head_ok=false
    fi

    if grep -qF "$BLOCK_TAIL_BEGIN" "$bashrc" 2>/dev/null; then
        pass "TAIL block present (ble-attach)"
    else
        fail "bash-customizations TAIL block missing from ~/.bashrc" \
             "bash setup.sh --skip-tools"
        tail_ok=false
    fi

    # Cannot check load order if the blocks are missing
    $head_ok || return

    # Helper: get 1-based line number of first match, or 0 if not found.
    _lineno() { grep -nm1 "$1" "$bashrc" 2>/dev/null | cut -d: -f1 || echo 0; }

    local ln_guard ln_head ln_tail
    ln_guard="$(_lineno '\[\[ \$- != \*i\*')"
    ln_head="$(grep -nF "$BLOCK_HEAD_BEGIN" "$bashrc" 2>/dev/null | head -1 | cut -d: -f1 || echo 0)"
    ln_tail="$(grep -nF "$BLOCK_TAIL_BEGIN" "$bashrc" 2>/dev/null | head -1 | cut -d: -f1 || echo 0)"

    # ── Non-interactive guard must precede the HEAD block ─────────────────────
    if [[ "$ln_guard" -gt 0 ]]; then
        pass "Non-interactive guard present (line ${ln_guard})"
        if [[ "$ln_head" -gt 0 && "$ln_guard" -gt "$ln_head" ]]; then
            fail "Non-interactive guard (line ${ln_guard}) appears AFTER HEAD block (line ${ln_head})" \
                 "Move [[ \$- != *i* ]] && return above the bash-customizations block"
        fi
    else
        warn "No non-interactive guard found in ~/.bashrc" \
             "Consider adding [[ \$- != *i* ]] && return before the bash-customizations block"
    fi

    # ── HEAD block must precede TAIL block ────────────────────────────────────
    if [[ "$ln_head" -gt 0 && "$ln_tail" -gt 0 && "$ln_head" -gt "$ln_tail" ]]; then
        fail "HEAD block (line ${ln_head}) appears AFTER TAIL block (line ${ln_tail})" \
             "bash setup.sh --skip-tools  (re-inject blocks)"
    fi

    # ── Content checks (grep by pattern — work the same as before) ────────────
    local ln_blesh_source ln_blesh_attach
    local ln_exports ln_history ln_completion ln_init ln_bindings
    local ln_functions ln_aliases ln_prompt

    ln_blesh_source="$(_lineno 'source.*attach=none')"
    ln_blesh_attach="$(_lineno '&&.*ble-attach\|^\s*ble-attach')"
    ln_exports="$(_lineno '[[:space:]_]*src.*exports\.sh\|source.*exports\.sh')"
    ln_history="$(_lineno '[[:space:]_]*src.*history\.sh\|source.*history\.sh')"
    ln_completion="$(_lineno '[[:space:]_]*src.*completion\.sh\|source.*completion\.sh')"
    ln_init="$(_lineno '[[:space:]_]*src.*init\.sh\|source.*init\.sh')"
    ln_bindings="$(_lineno '[[:space:]_]*src.*bindings\.sh\|source.*bindings\.sh')"
    ln_functions="$(_lineno '[[:space:]_]*src.*functions\.sh\|source.*functions\.sh')"
    ln_aliases="$(_lineno '[[:space:]_]*src.*aliases\.sh\|source.*aliases\.sh')"
    ln_prompt="$(_lineno '[[:space:]_]*src.*prompt\.sh\|source.*prompt\.sh')"

    if [[ "$ln_blesh_source" -eq 0 ]]; then
        fail "ble.sh --attach=none not found inside HEAD block" \
             "bash setup.sh --skip-tools"
    elif [[ "$ln_exports" -gt 0 && "$ln_blesh_source" -gt "$ln_exports" ]]; then
        fail "ble.sh source (line ${ln_blesh_source}) appears AFTER exports.sh (line ${ln_exports})" \
             "bash setup.sh --skip-tools  (re-inject blocks)"
    else
        pass "ble.sh --attach=none present (line ${ln_blesh_source})"
    fi

    declare -A module_lines=(
        [exports.sh]="$ln_exports"   [history.sh]="$ln_history"
        [completion.sh]="$ln_completion" [init.sh]="$ln_init"
        [bindings.sh]="$ln_bindings" [functions.sh]="$ln_functions"
        [aliases.sh]="$ln_aliases"   [prompt.sh]="$ln_prompt"
    )
    for mod in exports.sh history.sh completion.sh init.sh bindings.sh functions.sh aliases.sh prompt.sh; do
        local ln="${module_lines[$mod]}"
        if [[ "$ln" -gt 0 ]]; then
            pass "source ~/.bash/${mod} present (line ${ln})"
        else
            fail "source ~/.bash/${mod} missing from HEAD block" \
                 "bash setup.sh --skip-tools"
        fi
    done

    if [[ "$ln_exports" -gt 0 && "$ln_history" -gt 0 && "$ln_exports" -gt "$ln_history" ]]; then
        fail "exports.sh (line ${ln_exports}) loaded AFTER history.sh (line ${ln_history})" \
             "bash setup.sh --skip-tools"
    fi
    if [[ "$ln_completion" -gt 0 && "$ln_init" -gt 0 && "$ln_completion" -gt "$ln_init" ]]; then
        fail "completion.sh (line ${ln_completion}) loaded AFTER init.sh (line ${ln_init})" \
             "bash setup.sh --skip-tools"
    fi
    if [[ "$ln_prompt" -gt 0 && "$ln_blesh_attach" -gt 0 && "$ln_prompt" -gt "$ln_blesh_attach" ]]; then
        fail "prompt.sh (line ${ln_prompt}) loaded AFTER ble-attach (line ${ln_blesh_attach})" \
             "bash setup.sh --skip-tools"
    fi

    if [[ "$ln_blesh_attach" -eq 0 ]]; then
        fail "ble-attach not found in TAIL block" \
             "bash setup.sh --skip-tools"
    else
        pass "ble-attach present (line ${ln_blesh_attach})"
    fi

    local ln_fzf_bash
    ln_fzf_bash="$(_lineno 'eval.*fzf --bash')"
    if [[ "$ln_fzf_bash" -gt 0 && "$ln_blesh_source" -gt 0 ]]; then
        fail "eval \"\$(fzf --bash)\" found (line ${ln_fzf_bash}) alongside ble.sh — these conflict" \
             "Remove the eval line; fzf is handled via ~/.blerc"
    fi

    unset -f _lineno
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: starship.toml
# ══════════════════════════════════════════════════════════════════════════════

check_starship_toml() {
    log_section "starship.toml"

    local toml="${XDG_CONFIG_HOME}/starship.toml"

    if [[ -f "$toml" ]]; then
        pass "starship.toml exists: ${toml}"
        # Sanity-check it's actually TOML (has at least one section header)
        if grep -q '^\[' "$toml" 2>/dev/null; then
            pass "starship.toml appears well-formed"
        else
            warn "starship.toml may be empty or malformed" \
                 "Check the file; re-deploy with: bash setup.sh --skip-tools"
        fi
    elif [[ -L "$toml" ]]; then
        fail "starship.toml is a dangling symlink" \
             "bash setup.sh --skip-tools"
    else
        fail "starship.toml missing at ${toml}" \
             "bash setup.sh --skip-tools"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Check: history file
# ══════════════════════════════════════════════════════════════════════════════

check_history() {
    log_section "History"

    local hist_file="${HISTFILE:-${HOME}/.bash_history}"

    if [[ ! -e "$hist_file" ]]; then
        info "History file ${hist_file} does not exist yet (created on first exit)"
        return
    fi

    if [[ -w "$hist_file" ]]; then
        local lines
        lines="$(wc -l < "$hist_file" | tr -d ' ')"
        pass "History file writable: ${hist_file}  (${lines} lines)"
    else
        fail "History file is NOT writable: ${hist_file}" \
             "chmod u+w ${hist_file}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════

print_summary() {
    echo
    echo "────────────────────────────────────────────────────────"
    if [[ "$ISSUES" -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All checks passed.${RESET}  Setup looks healthy."
    elif [[ "$ISSUES" -eq 1 ]]; then
        echo -e "  ${YELLOW}${BOLD}1 issue found.${RESET}  See above for fix instructions."
    else
        echo -e "  ${RED}${BOLD}${ISSUES} issues found.${RESET}  See above for fix instructions."
    fi
    echo
    echo "  Quick recovery commands:"
    echo "    bash setup.sh --skip-tools   Re-deploy dotfiles (fixes broken symlinks)"
    echo "    bash setup.sh                Re-run full install"
    echo "    bash uninstall.sh --restore  Restore your backup (undo everything)"
    echo "    bash uninstall.sh --list-backups   See available backups"
    echo "────────────────────────────────────────────────────────"
}

print_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║        bash-customizations  doctor.sh            ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
    print_banner

    check_bash_version
    check_path
    check_tools
    check_blesh
    check_bash_completion
    check_manifest
    check_symlinks
    check_bashrc
    check_starship_toml
    check_history

    print_summary

    [[ "$ISSUES" -eq 0 ]]   # exit 0 if healthy, 1 if any issues
}

main "$@"
