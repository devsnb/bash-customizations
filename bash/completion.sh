#!/usr/bin/env bash
# ~/.bash/completion.sh
#
# bash-completion v2 setup.
# Most distros already source this via /etc/profile.d/; this file handles
# the cases where they don't (e.g. macOS with Homebrew, minimal containers).
#
# bash-completion latest: v2.17.0  (https://github.com/scop/bash-completion)
# ─────────────────────────────────────────────────────────────────────────────

# ── Guard: already loaded? ────────────────────────────────────────────────────
# BASH_COMPLETION_VERSINFO is set by bash-completion v2 on load.
if [[ -n "${BASH_COMPLETION_VERSINFO:-}" ]]; then
    return 0
fi

# ── Linux / generic Unix ──────────────────────────────────────────────────────
_bc_linux=(
    /usr/share/bash-completion/bash_completion   # Debian / Ubuntu / Fedora / Arch
    /usr/local/share/bash-completion/bash_completion  # manual / BSD install
    /etc/bash_completion                          # older distros
)

for _bc_file in "${_bc_linux[@]}"; do
    if [[ -f "$_bc_file" ]]; then
        # shellcheck source=/dev/null
        source "$_bc_file"
        break
    fi
done
unset _bc_file _bc_linux

# ── macOS (Homebrew) ──────────────────────────────────────────────────────────
# Homebrew stores the prefix in $HOMEBREW_PREFIX (set since Homebrew 3.x).
# Fallback to the default Intel and Apple-Silicon locations.
if [[ "$OSTYPE" == darwin* ]] && [[ -z "${BASH_COMPLETION_VERSINFO:-}" ]]; then
    _bc_brew_prefix="${HOMEBREW_PREFIX:-}"

    if [[ -z "$_bc_brew_prefix" ]] && command -v brew &>/dev/null; then
        _bc_brew_prefix="$(brew --prefix)"
    fi

    # Only probe Homebrew paths when we actually found a prefix.
    # An empty prefix would form paths like /etc/... which are Linux system
    # paths and must never be sourced on macOS.
    if [[ -n "$_bc_brew_prefix" ]]; then
        for _bc_brew_script in \
            "${_bc_brew_prefix}/etc/profile.d/bash_completion.sh" \
            "${_bc_brew_prefix}/share/bash-completion/bash_completion"; do
            if [[ -f "$_bc_brew_script" ]]; then
                # shellcheck source=/dev/null
                source "$_bc_brew_script"
                break
            fi
        done
    fi
    unset _bc_brew_prefix _bc_brew_script
fi

# ── User-level completions ────────────────────────────────────────────────────
# Drop files in ~/.local/share/bash-completion/completions/ and they are
# lazy-loaded automatically (requires bash-completion v2).
# No extra code needed here — the directory is the standard XDG location that
# bash-completion already knows about.

# ── Completion quality-of-life tweaks ────────────────────────────────────────
# Case-insensitive filename completion (type "cd dow<TAB>" → "Downloads/")
bind "set completion-ignore-case on" 2>/dev/null

# Treat hyphens and underscores as equivalent during completion.
bind "set completion-map-case on" 2>/dev/null

# Show all matches on the first ambiguous TAB press (skip the double-TAB ritual).
bind "set show-all-if-ambiguous on" 2>/dev/null

# Add a trailing slash when completing a directory name.
bind "set mark-symlinked-directories on" 2>/dev/null

# Colour ls-style output in the completion menu.
bind "set colored-stats on" 2>/dev/null

# Highlight the common prefix of possible completions.
bind "set colored-completion-prefix on" 2>/dev/null

# Show completion type (file, dir, …) in the menu.
bind "set visible-stats on" 2>/dev/null

# Append a character indicating the file type when listing completions.
bind "set mark-directories on" 2>/dev/null
