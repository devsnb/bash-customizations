-- lazy.nvim bootstrap and plugin loading.
--
-- This file installs lazy.nvim on first launch, adds it to Neovim's runtimepath,
-- then imports plugin specs from `lua/plugins/`. Keeping plugin definitions in
-- separate files makes the setup easier to maintain: UI, editor tooling, LSP,
-- and syntax support can evolve independently.

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

-- Bootstrap lazy.nvim if it is not installed yet. This mirrors lazy.nvim's
-- recommended setup and avoids requiring a separate manual installation step.
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local repo = "https://github.com/folke/lazy.nvim.git"
    local out = vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "--branch=stable",
        repo,
        lazypath,
    })

    -- If cloning fails, show the Git output in Neovim rather than failing with
    -- an unreadable Lua stack trace. The rest of the editor can still open.
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n",      "ErrorMsg" },
            { out,                                 "WarningMsg" },
            { "\nInstall git and restart Neovim.", "Comment" },
        }, true, {})
        return
    end
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
    spec = {
        -- Imports every Lua module under `lua/plugins/`.
        { import = "plugins" },
    },
    -- Fallback colorschemes used while plugins are being installed.
    install = { colorscheme = { "tokyonight", "habamax" } },
    -- Check for plugin updates quietly; update manually from `:Lazy`.
    checker = { enabled = true, notify = false },
    change_detection = { notify = false },
    ui = { border = "rounded" },
})
