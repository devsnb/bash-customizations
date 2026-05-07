#!/usr/bin/env bash
# ~/.bash/prompt.sh
#
# Prompt initialisation — Starship.
#
# Starship MUST be initialised last among prompt-related tools (after fzf,
# zoxide, etc.) because it installs its own PROMPT_COMMAND hook.  ble-attach
# in ~/.bashrc comes after this file.
#
# Starship latest: v1.25.1  (https://starship.rs)
# Config file    : ~/.config/starship.toml  (see starship.toml in this repo)
# ─────────────────────────────────────────────────────────────────────────────

if command -v starship &>/dev/null; then
    eval "$(starship init bash)"
else
    # Minimal fallback prompt — no git status, language info, or timestamps.
    # This is intentionally simple to avoid any dependency on external tools.
    # Install Starship with `bash setup.sh` to restore the full prompt.
    # Format: user@host:~/current/dir $
    PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi
