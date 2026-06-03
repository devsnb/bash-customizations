-- LSP, language-server installation, diagnostics, and completion.
--
-- Neovim v0.12 includes a modern built-in LSP client. This file uses the
-- Neovim 0.11+ style APIs (`vim.lsp.config`) together with nvim-lspconfig's
-- server defaults. Mason is used only to install/manage external language
-- servers; Neovim itself owns the client configuration.

return {
    {
        -- Mason provides `:Mason`, a UI for installing external tools such as
        -- language servers, linters, and formatters into Neovim's data dir.
        "mason-org/mason.nvim",
        cmd = "Mason",
        opts = {
            ui = { border = "rounded" },
        },
    },

    {
        -- Bridges Mason and nvim-lspconfig. `ensure_installed` bootstraps a
        -- useful default set, while `automatic_enable` calls `vim.lsp.enable()`
        -- for installed servers using nvim-lspconfig's defaults.
        "mason-org/mason-lspconfig.nvim",
        dependencies = {
            "mason-org/mason.nvim",
            "neovim/nvim-lspconfig",
        },
        opts = {
            ensure_installed = {
                "bashls",
                "jsonls",
                "lua_ls",
                "marksman",
                "yamlls",
            },
            automatic_enable = true,
        },
    },

    {
        -- nvim-lspconfig contributes server definitions. We keep custom config
        -- minimal so future server defaults from the plugin continue to apply.
        "neovim/nvim-lspconfig",
        dependencies = { "saghen/blink.cmp" },
        event = { "BufReadPre", "BufNewFile" },
        config = function()
            -- Global diagnostic presentation: signs in the gutter, concise
            -- virtual text, sorted severities, and rounded floating windows.
            vim.diagnostic.config({
                virtual_text = { prefix = "●", spacing = 2 },
                signs = {
                    text = {
                        [vim.diagnostic.severity.ERROR] = "",
                        [vim.diagnostic.severity.WARN] = "",
                        [vim.diagnostic.severity.INFO] = "",
                        [vim.diagnostic.severity.HINT] = "󰌵",
                    },
                },
                underline = true,
                update_in_insert = false,
                severity_sort = true,
                float = { border = "rounded", source = "if_many" },
            })

            -- Extend LSP capabilities with blink.cmp completion support. The
            -- wildcard config applies these capabilities to every server that
            -- nvim-lspconfig/mason-lspconfig enables later.
            local capabilities = vim.lsp.protocol.make_client_capabilities()
            local ok, blink = pcall(require, "blink.cmp")
            if ok then
                capabilities = blink.get_lsp_capabilities(capabilities)
            end
            vim.lsp.config("*", { capabilities = capabilities })

            -- Lua language server tweaks for editing this Neovim config: use
            -- LuaJIT, accept the global `vim`, and avoid third-party prompts.
            vim.lsp.config("lua_ls", {
                settings = {
                    Lua = {
                        runtime = { version = "LuaJIT" },
                        diagnostics = { globals = { "vim" } },
                        workspace = { checkThirdParty = false },
                        telemetry = { enable = false },
                    },
                },
            })
        end,
    },

    {
        -- Fast completion engine with LSP, path, snippet, and buffer sources.
        -- It is lazy-loaded on insert mode to keep startup quick.
        "saghen/blink.cmp",
        version = "1.*",
        event = "InsertEnter",
        opts = {
            keymap = { preset = "default" },
            appearance = { nerd_font_variant = "mono" },
            completion = {
                documentation = { auto_show = true, auto_show_delay_ms = 250 },
                menu = { border = "rounded" },
            },
            signature = { enabled = true, window = { border = "rounded" } },
            sources = { default = { "lsp", "path", "snippets", "buffer" } },
        },
    },
}
