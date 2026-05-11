#!/usr/bin/env bash
# ~/.bash/init.sh
#
# Third-party tool initialization: fzf → zoxide.
#
# IMPORTANT — ble.sh lifecycle (two-part split):
#   Part 1 (attach=none) lives at the TOP of ~/.bashrc, before everything.
#   Part 2 (ble-attach)  lives at the BOTTOM of ~/.bashrc, after prompt.sh.
# Both parts are managed in ~/.bashrc directly, NOT here, so that the
# correct ordering contract is always enforced.
#
# Tool versions this file was written for:
#   fzf    v0.62.0  (https://github.com/junegunn/fzf)
#   zoxide v0.9.9   (https://github.com/ajeetdsouza/zoxide)
# ─────────────────────────────────────────────────────────────────────────────

# ── fzf ───────────────────────────────────────────────────────────────────────
# `fzf --bash` (available since fzf v0.48.0) initialises all three bindings:
#   CTRL-T  file picker
#   CTRL-R  history search
#   ALT-C   cd into directory
#
# When ble.sh is active we use ble.sh's built-in fzf integration modules
# instead, which avoids keymap conflicts.  See ~/.blerc for that config.
if command -v fzf &>/dev/null; then
    if [[ -n "${BLE_VERSION:-}" ]]; then
        # ble.sh is running — delegate fzf key-bindings to ~/.blerc
        # (ble-import calls are made there; nothing to do here)
        :
    else
        # Plain readline — use fzf's native init
        eval "$(fzf --bash)"
    fi
fi

# ── zoxide ────────────────────────────────────────────────────────────────────
# Provides the `z` command (smart cd with frecency ranking) and
# `zi` (interactive selection via fzf).
#
# Flags:
#   (none)       → adds `z` and `zi`, leaves the real `cd` untouched
#   --cmd cd     → replaces `cd` with zoxide entirely (uncomment to enable)
if command -v zoxide &>/dev/null; then
    eval "$(zoxide init bash)"
    # eval "$(zoxide init bash --cmd cd)"   # ← uncomment to replace `cd`
fi
