-- Autocommands for small quality-of-life behaviours.
--
-- Autocommands react to editor events. This file intentionally keeps them
-- minimal and side-effect free: visual feedback on yank, filetype correction
-- for env files, and whitespace cleanup before writing buffers.

local group = vim.api.nvim_create_augroup("user-config", { clear = true })

-- Highlight text briefly after yanking so copy operations have visual feedback.
vim.api.nvim_create_autocmd("TextYankPost", {
    group = group,
    desc = "Briefly highlight yanked text",
    callback = function()
        vim.highlight.on_yank({ timeout = 180 })
    end,
})

-- Treat `.env` files as shell-like files to get useful highlighting and LSP
-- behaviour without needing a separate env-file plugin.
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    group = group,
    pattern = { "*.env", ".env.*" },
    desc = "Use shell filetype for env files",
    callback = function()
        vim.bo.filetype = "sh"
    end,
})

-- Remove trailing whitespace on save while preserving the user's cursor/view.
-- `keeppatterns` prevents this cleanup from overwriting the last search term.
vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    desc = "Trim trailing whitespace on save",
    callback = function()
        local save = vim.fn.winsaveview()
        vim.cmd([[keeppatterns %s/\s\+$//e]])
        vim.fn.winrestview(save)
    end,
})
