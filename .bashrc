#!/usr/bin/env bash
# ~/.bashrc  — REFERENCE / STANDALONE FILE
#
# setup.sh no longer deploys this file as a symlink.
# Instead it injects two managed blocks directly into your existing ~/.bashrc:
#
#   # === BEGIN bash-customizations ===       ← ble.sh Part 1 + all modules
#   # === END bash-customizations ===
#
#   # === BEGIN bash-customizations-attach === ← ble-attach (must be last)
#   # === END bash-customizations-attach ===
#
# This file is kept for two purposes:
#   1. Documentation — shows the intended load order and all module sources.
#   2. Standalone use — if you prefer to manage your own ~/.bashrc, you can
#      source this file directly from it:
#        source ~/bash-customizations/.bashrc
#      In that case you must ensure this source line is at the correct position
#      (see load order below) and that ble-attach follows at the end.
#
# Load order (matters!):
#   0. ble.sh  Part 1  — must be FIRST (before any other setup)
#   1. exports.sh      — PATH, env vars, tool options
#   2. history.sh      — HISTSIZE, HISTCONTROL, histappend, PROMPT_COMMAND
#   3. completion.sh   — bash-completion v2 + readline tweaks
#   4. init.sh         — fzf (when ble.sh absent), zoxide
#   5. bindings.sh     — key bindings
#   6. functions.sh    — shell functions
#   7. aliases.sh      — aliases
#   8. prompt.sh       — Starship (sets PROMPT_COMMAND / PS1)
#   9. help.sh         — the `cheatsheet` command (no ordering constraints,
#                        so it goes last rather than renumbering everything)
#  10. ble.sh  Part 2  — must be LAST (attaches after full env is ready)
# ─────────────────────────────────────────────────────────────────────────────

# ── Guard: non-interactive shells get nothing ─────────────────────────────────
# $- holds the current shell's option flags as a string (e.g. "himBH").
# The letter 'i' is present only in interactive shells. This line exits
# immediately for non-interactive shells (scripts, ssh -c, scp, etc.)
# so they don't inherit aliases, completions, or a modified PATH.
[[ $- != *i* ]] && return

# ── 0. ble.sh — Part 1: load WITHOUT attaching ───────────────────────────────
# Source ble.sh here so it can observe the rest of .bashrc, but defer the
# actual attach until the very end (after Starship has set up its hooks).
# The `--attach=none` flag prevents ble.sh from taking over readline yet.
_blesh="${XDG_DATA_HOME:-$HOME/.local/share}/blesh/ble.sh"
if [[ -f "$_blesh" ]]; then
    # shellcheck source=/dev/null
    source -- "$_blesh" --attach=none
fi
unset _blesh  # keep the environment clean; ble.sh has already stored the path internally

# _src — source a module file with a helpful error if it is missing.
# A missing module means setup is incomplete; warn but continue so the
# shell is at least partially usable rather than silently broken.
_src() {
    if [[ -f "$1" ]]; then
        # shellcheck source=/dev/null
        source "$1"
    else
        echo "bashrc: WARNING — module not found: $1" \
             "(run: bash ~/bash-customizations/setup.sh --skip-tools)" >&2
    fi
}

# ── 1. Environment variables & PATH ──────────────────────────────────────────
_src "$HOME/.bash/exports.sh"

# ── 2. History settings ───────────────────────────────────────────────────────
_src "$HOME/.bash/history.sh"

# ── 3. bash-completion ────────────────────────────────────────────────────────
_src "$HOME/.bash/completion.sh"

# ── 4. Tool initialisation (fzf, zoxide) ─────────────────────────────────────
_src "$HOME/.bash/init.sh"

# ── 5. Key bindings ───────────────────────────────────────────────────────────
_src "$HOME/.bash/bindings.sh"

# ── 6. Shell functions ────────────────────────────────────────────────────────
_src "$HOME/.bash/functions.sh"

# ── 7. Aliases ───────────────────────────────────────────────────────────────
_src "$HOME/.bash/aliases.sh"

# ── 8. Prompt (Starship) ──────────────────────────────────────────────────────
_src "$HOME/.bash/prompt.sh"

# ── 9. cheatsheet ─────────────────────────────────────────────────────────────
_src "$HOME/.bash/help.sh"

unset -f _src

# ── 10. ble.sh — Part 2: attach NOW (after Starship has registered its hooks) ──
# ble-attach hands readline control to ble.sh.  It must be the absolute
# last interactive statement in this file.
[[ ${BLE_VERSION:-} ]] && ble-attach
