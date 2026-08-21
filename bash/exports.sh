#!/usr/bin/env bash
# ~/.bash/exports.sh
#
# Environment variables and PATH configuration.
# Sourced first so every subsequent module inherits these values.
# ─────────────────────────────────────────────────────────────────────────────

# ── Editor ────────────────────────────────────────────────────────────────────
export EDITOR="${EDITOR:-nano}"
export VISUAL="${VISUAL:-$EDITOR}"

# ── Locale ────────────────────────────────────────────────────────────────────
# Rules:
#   1. Only override LANG if it isn't already set by the system.
#   2. Check that the locale actually exists on this machine before using it.
#   3. NEVER set LC_ALL here.  LC_ALL is the nuclear option — it overrides
#      every other LC_* variable, and forcing a non-existent locale causes
#      ble.sh to fall back to single-byte mode, which makes terminal escape
#      sequences (DA2, CPR, …) leak into the readline buffer as literal text.
#
# If you see "cannot change locale" warnings, install the locale:
#   sudo apt-get install -y locales
#   sudo locale-gen en_US.UTF-8
#   sudo update-locale LANG=en_US.UTF-8
#   # then open a new terminal
if [[ -z "${LANG:-}" ]]; then
    if locale -a 2>/dev/null | grep -qiE 'en_US\.(UTF-8|utf8)'; then
        export LANG="en_US.UTF-8"
    elif locale -a 2>/dev/null | grep -qiE '^C\.UTF'; then
        export LANG="C.UTF-8"      # always available on modern systems
    else
        export LANG="C"            # last resort: POSIX locale
    fi
fi

# ── Pager ─────────────────────────────────────────────────────────────────────
export PAGER="${PAGER:-less}"
# -R  : pass ANSI colour codes through
# -F  : quit if output fits on one screen
# -X  : don't clear screen on exit
export LESS="${LESS:--RFX}"

# ── XDG Base Directories ──────────────────────────────────────────────────────
# Many modern tools respect these; defining them explicitly avoids surprises.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# ── PATH ──────────────────────────────────────────────────────────────────────
# Helper: prepend a directory to PATH only if it exists and isn't already there.
_prepend_path() {
    [[ -d "$1" && ":$PATH:" != *":$1:"* ]] && PATH="$1:$PATH"
}

_prepend_path "$HOME/.local/bin"   # user-installed tools (starship, ble.sh, zoxide …)
_prepend_path "$HOME/bin"          # personal scripts
_prepend_path "$HOME/.cargo/bin"   # Rust / cargo binaries

export PATH
unset -f _prepend_path

# ── fzf ───────────────────────────────────────────────────────────────────────
# Default command used by fzf when no input is given (requires fd or rg).
# Falls back gracefully if fd/rg is not installed.
if command -v fd &>/dev/null; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
elif command -v rg &>/dev/null; then
    export FZF_DEFAULT_COMMAND='rg --files --hidden --follow --glob "!.git"'
fi

# Global fzf UI options
export FZF_DEFAULT_OPTS="
  --height=50%
  --layout=reverse
  --border=rounded
  --info=inline
  --prompt='  '
  --pointer='▶'
  --marker='✓'
  --bind='ctrl-/:toggle-preview'
  --bind='?:toggle-preview'
  --color=fg:#cdd6f4,hl:#f38ba8
  --color=fg+:#cdd6f4,bg+:#313244,hl+:#f38ba8
  --color=info:#cba6f7,prompt:#89dceb,pointer:#f5c2e7
  --color=marker:#a6e3a1,spinner:#f5c2e7,header:#87afaf
"

# CTRL-T  — file picker
export FZF_CTRL_T_OPTS="
  --preview='cat {}'
  --preview-window=right:60%:wrap
"

# CTRL-R  — history search
export FZF_CTRL_R_OPTS="
  --preview='echo {}'
  --preview-window=down:3:hidden:wrap
  --bind='ctrl-/:toggle-preview'
  --bind='ctrl-y:execute-silent(echo -n {2..} | xclip -selection clipboard 2>/dev/null || echo -n {2..} | wl-copy 2>/dev/null || echo -n {2..} | pbcopy 2>/dev/null)+abort'
  --color=header:italic
  --header='Press CTRL-Y to copy command into clipboard'
"

# ALT-C   — directory jump
export FZF_ALT_C_OPTS="
  --preview='ls -la {}'
  --preview-window=right:50%
"

# ── zoxide ────────────────────────────────────────────────────────────────────
# Print the matched directory path before jumping (helpful for verification).
export _ZO_ECHO=1

# ── Starship ──────────────────────────────────────────────────────────────────
export STARSHIP_CONFIG="${XDG_CONFIG_HOME}/starship.toml"

# ── Man pages — coloured output ───────────────────────────────────────────────
export MANPAGER="less -R --use-color -Dd+r -Du+b"
export MANROFFOPT="-P -c"
