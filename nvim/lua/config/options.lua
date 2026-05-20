-- Core editor options.
--
-- This module contains only built-in Neovim settings. Plugin-specific settings
-- live in `lua/plugins/*.lua`, so the baseline editor remains understandable
-- even before plugins are installed. The goal is a modern default experience:
-- relative line numbers, clean UI, sensible indentation, persistent undo, and
-- fast feedback for completion/LSP events.

local opt = vim.opt

-- Leader keys must be set before lazy.nvim loads any plugin mappings.
-- Space is easy to reach and is the common default in many modern configs.
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Line numbers and sign column.
-- `number` shows the absolute current line, while `relativenumber` makes
-- motions like `5j`, `3k`, and operator-pending commands easier to perform.
opt.number = true
opt.relativenumber = true
opt.signcolumn = "yes" -- Keep diagnostic/git signs from shifting text.

-- Editing experience.
opt.mouse = "a"               -- Allow mouse interaction in splits, popups, and visual mode.
opt.clipboard = "unnamedplus" -- Use the system clipboard when available.
opt.breakindent = true        -- Wrapped lines preserve indentation visually.
opt.expandtab = true          -- Spaces instead of literal tab characters.
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.smartindent = true
opt.undofile = true  -- Persist undo history across sessions.
opt.updatetime = 250 -- Faster CursorHold and diagnostic updates.
opt.timeoutlen = 400 -- Snappy mapped-key timeout without feeling rushed.
opt.completeopt = { "menu", "menuone", "noselect" }

-- Search behaviour.
-- Case-insensitive by default, but automatically case-sensitive when the search
-- pattern contains uppercase characters.
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- User interface.
opt.termguicolors = true
opt.cursorline = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.splitright = true
opt.splitbelow = true
opt.showmode = false          -- Statusline handles mode display.
opt.wrap = false
opt.list = true               -- Make invisible whitespace visible but subtle.
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
opt.fillchars = { eob = " " } -- Hide `~` filler lines for a cleaner look.

-- File safety/preferences.
-- Swap/backup files are disabled because persistent undo is enabled and this
-- keeps project directories free of editor artifacts.
opt.swapfile = false
opt.backup = false

-- Neovim 0.12 supports the `winborder` option, which gives built-in floating
-- windows a consistent rounded border without configuring each one manually.
opt.winborder = "rounded"
