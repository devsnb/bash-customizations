-- Entry point for the Neovim setup managed by this dotfiles repository.
--
-- This file is intentionally tiny: it only defines the load order for the
-- configuration modules under `lua/config/`. Keeping startup orchestration here
-- makes it easy for someone new to the repo to understand where each concern
-- lives:
--   1. `options`  — editor defaults such as line numbers, indentation, UI.
--   2. `keymaps`  — global mappings and LSP buffer-local mappings.
--   3. `autocmds` — small automated behaviours on editor events.
--   4. `lazy`     — plugin manager bootstrap and plugin spec loading.
--
-- Target compatibility: Neovim v0.12.2+.

require("config.options")
require("config.keymaps")
require("config.autocmds")
require("config.lazy")
