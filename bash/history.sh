#!/usr/bin/env bash
# ~/.bash/history.sh
#
# Shell history configuration.
# Goals: large persistent history, no duplicates, immediate save, useful ignore list.
# ─────────────────────────────────────────────────────────────────────────────

# ── Size ──────────────────────────────────────────────────────────────────────
# HISTSIZE     : number of entries kept in memory (current session)
# HISTFILESIZE : number of entries written to the history file (~/.bash_history)
HISTSIZE=100000
HISTFILESIZE=200000

# ── Deduplication & filtering ─────────────────────────────────────────────────
# ignoredups  : don't record a command that is identical to the previous entry
# erasedups   : remove ALL previous duplicates of a command before recording it
#               (keeps the most-recent occurrence at the end of the file)
HISTCONTROL=ignoredups:erasedups

# Commands that are too short or too common to be worth saving.
# Separate patterns with colons.  Globs are allowed.
# ' *' (space-star) — any command prefixed with a leading space is silently
# omitted from history. Useful for sensitive commands (passwords, tokens, etc.)
# e.g.:  <space>AWS_SECRET=abc aws s3 ...   ← never recorded
HISTIGNORE="ls:ls *:ll:la:l:cd:cd -:pwd:exit:clear:history:bg:fg:jobs: *"

# ── Timestamps ────────────────────────────────────────────────────────────────
# Store the time each command was run.
# Format: "[ 2025-06-04 14:23:01 ] "
HISTTIMEFORMAT="[ %F %T ] "

# ── Shell options ─────────────────────────────────────────────────────────────
# Append to the history file instead of overwriting it on shell exit.
# This preserves history across multiple simultaneous terminal sessions.
shopt -s histappend

# Allow multi-line commands to be stored as a single history entry.
shopt -s cmdhist

# Re-edit a failed history substitution rather than silently discarding it.
shopt -s histreedit

# ── Immediate write + sync ────────────────────────────────────────────────────
# After every command:
#   history -a  → append this shell's new entry to the history file
#   history -n  → read only entries appended by other shells since the last sync
#
# Clearing and re-reading the entire file made every prompt O(history size), up
# to HISTFILESIZE lines.  Incremental reads keep cross-window sharing without
# reparsing as many as 200,000 entries after every command.
#
# We prepend to any existing PROMPT_COMMAND rather than replacing it.
# When ble.sh is active it replaces PROMPT_COMMAND at attach time, making this
# hook unreachable.  ble.sh provides its own history sync via bleopt history_share
# in ~/.blerc — no duplicate setup needed here.
if [[ -z "${BLE_VERSION:-}" ]]; then
    _bc_history_sync() {
        history -a
        history -n
        return 0
    }

    # Bash 5.1 changed PROMPT_COMMAND to support array form.
    # Handle both array and scalar safely, and stay idempotent when `reload`
    # sources ~/.bashrc again.
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        _bc_hist_hook_present=false
        for _bc_hist_hook in "${PROMPT_COMMAND[@]+"${PROMPT_COMMAND[@]}"}"; do
            [[ "$_bc_hist_hook" == "_bc_history_sync" ]] && _bc_hist_hook_present=true
        done
        $_bc_hist_hook_present || PROMPT_COMMAND+=("_bc_history_sync")
        unset _bc_hist_hook _bc_hist_hook_present
    elif [[ -z "${PROMPT_COMMAND:-}" ]]; then
        PROMPT_COMMAND="_bc_history_sync"
    elif [[ "${PROMPT_COMMAND}" != *"_bc_history_sync"* ]]; then
        PROMPT_COMMAND="_bc_history_sync; ${PROMPT_COMMAND}"
    fi
fi
