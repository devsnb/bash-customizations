#!/usr/bin/env bash
# ~/.bash/completion.sh
#
# bash-completion v2 setup.
# Most distros already source this via /etc/profile.d/; this file handles
# minimal containers and manual Linux installations where they do not.
#
# bash-completion latest: v2.17.0  (https://github.com/scop/bash-completion)
# ─────────────────────────────────────────────────────────────────────────────

# ── Guard: already loaded? ────────────────────────────────────────────────────
# BASH_COMPLETION_VERSINFO is set by bash-completion v2 on load.
if [[ -n "${BASH_COMPLETION_VERSINFO:-}" ]]; then
    return 0
fi

# ── Linux ─────────────────────────────────────────────────────────────────────
_bc_linux=(
    /usr/share/bash-completion/bash_completion   # Debian / Ubuntu / Fedora / Arch
    /usr/local/share/bash-completion/bash_completion  # manual install
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
