#!/usr/bin/env bash
# ~/.bash/bindings.sh
#
# Readline / ble.sh key bindings.
#
# When ble.sh is active most of these are superseded by ble.sh's own keymap,
# but they are harmless to define — ble.sh merges them in rather than ignoring them.
# ─────────────────────────────────────────────────────────────────────────────

# ── Readline options (inputrc-equivalent, applied at runtime) ─────────────────
# Use vi mode instead of emacs mode (uncomment if preferred).
# bind "set editing-mode vi"

# Emacs mode (default — explicit is better than implicit).
bind "set editing-mode emacs" 2>/dev/null

# ── History navigation ────────────────────────────────────────────────────────
# Arrow keys search history based on what's already typed.
# e.g. type "git " then press ↑ to cycle only git commands.
bind '"\e[A": history-search-backward' 2>/dev/null   # ↑ Up arrow
bind '"\e[B": history-search-forward'  2>/dev/null   # ↓ Down arrow

# Same for CTRL-P / CTRL-N (emacs-style navigation).
bind '"\C-p": history-search-backward' 2>/dev/null
bind '"\C-n": history-search-forward'  2>/dev/null

# ── Word movement ─────────────────────────────────────────────────────────────
# ALT-← / ALT-→  move one word at a time.
# Sequences \e[1;3C / \e[1;3D work in xterm-compatible terminals
# (GNOME Terminal, Windows Terminal, kitty, Alacritty).
# macOS Terminal.app sends \033f / \033b instead — adjust if ALT+arrow is broken.
bind '"\e[1;3C": forward-word'  2>/dev/null   # ALT-→
bind '"\e[1;3D": backward-word' 2>/dev/null   # ALT-←

# ── Editing shortcuts ─────────────────────────────────────────────────────────
# CTRL-X CTRL-E  open the current line in $EDITOR for multi-line editing.
bind '"\C-x\C-e": edit-command-line' 2>/dev/null

# ── Misc ──────────────────────────────────────────────────────────────────────
# When completing mid-word, don't re-insert the already-typed suffix.
# e.g. cursor between 'gi' and 't': TAB completes 'git' not 'gitt'.
bind "set skip-completed-text on" 2>/dev/null

# Show all matches after a single TAB when the common prefix can't be extended.
# Without this, a second TAB is required to list alternatives.
bind "set show-all-if-unmodified on" 2>/dev/null

# ── ble.sh extra bindings ─────────────────────────────────────────────────────
# These are applied only when ble.sh is running.
# ble.sh has its own sophisticated history search (C-r) so we don't override it.
if [[ -n "${BLE_VERSION:-}" ]]; then
    # ble.sh is active. Use ble-bind for ble.sh-specific key bindings.
    # Main ble.sh settings (highlight colours, completion, vi mode) live in
    # ~/.blerc which is sourced automatically by ble.sh after attach.
    #
    # Example ble.sh bindings (uncomment to enable):
    #   ble-bind -f 'C-x C-f'  'complete file'
    #
    # Full key-binding reference:
    #   https://github.com/akinomyoga/ble.sh/wiki/Manual-%C2%A72-Key-Binding
    :
fi
