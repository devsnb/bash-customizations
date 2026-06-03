-- Visual/UI plugins.
--
-- This module is responsible for the look and feel of Neovim: colorscheme,
-- statusline, indentation guides, keybinding hints, notifications, and the
-- command-palette style `:` prompt. Functional editor tooling lives in
-- `editor.lua`, LSP/completion in `lsp.lua`, and Treesitter in `syntax.lua`.

return {
    {
        -- Colorscheme loaded early so every later plugin can use its highlight
        -- groups. `priority = 1000` ensures it wins startup ordering.
        "folke/tokyonight.nvim",
        lazy = false,
        priority = 1000,
        opts = {
            style = "moon",
            transparent = false,
            styles = {
                comments = { italic = true },
                keywords = { italic = true },
            },
        },
        config = function(_, opts)
            require("tokyonight").setup(opts)
            vim.cmd.colorscheme("tokyonight")
        end,
    },

    {
        -- Statusline with global status across splits. Devicons are optional
        -- visual polish and depend on using a Nerd Font in the terminal.
        "nvim-lualine/lualine.nvim",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        opts = {
            options = {
                theme = "tokyonight",
                globalstatus = true,
                component_separators = { left = "", right = "" },
                section_separators = { left = "", right = "" },
            },
        },
    },

    {
        -- Indentation guides make nested code easier to scan. Scope highlighting
        -- is enabled, but start/end markers are hidden for a cleaner look.
        "lukas-reineke/indent-blankline.nvim",
        main = "ibl",
        event = { "BufReadPost", "BufNewFile" },
        opts = {
            indent = { char = "│" },
            scope = { enabled = true, show_start = false, show_end = false },
        },
    },

    {
        -- which-key displays available mappings after pressing the leader key.
        -- This makes the setup discoverable without memorising every shortcut.
        "folke/which-key.nvim",
        event = "VeryLazy",
        opts = {
            preset = "modern",
            delay = 250,
            icons = { mappings = true },
        },
    },

    {
        -- Notification renderer used by noice.nvim for nicer message popups.
        "rcarriga/nvim-notify",
        event = "VeryLazy",
        opts = {
            timeout = 3000,
            render = "compact",
            stages = "fade_in_slide_out",
            background_colour = "#1a1b26",
        },
    },

    {
        -- noice.nvim replaces the bottom command line with a command-palette
        -- style popup. This is what makes commands like `:q`, `:w`, and `/foo`
        -- appear in a centered, rounded prompt rather than the default cmdline.
        "folke/noice.nvim",
        event = "VeryLazy",
        dependencies = {
            "MunifTanjim/nui.nvim",
            "rcarriga/nvim-notify",
        },
        keys = {
            { "<leader>nh", "<cmd>Noice history<CR>", desc = "Notification history" },
            { "<leader>nl", "<cmd>Noice last<CR>",    desc = "Last notification" },
            { "<leader>nd", "<cmd>Noice dismiss<CR>", desc = "Dismiss notifications" },
        },
        opts = {
            cmdline = {
                enabled = true,
                view = "cmdline_popup",
                format = {
                    -- Different prompt icons/languages give better highlighting
                    -- for Vim commands, search, shell commands, Lua, and help.
                    cmdline = { pattern = "^:", icon = "", lang = "vim" },
                    search_down = { kind = "search", pattern = "^/", icon = " ", lang = "regex" },
                    search_up = { kind = "search", pattern = "^%?", icon = " ", lang = "regex" },
                    filter = { pattern = "^:%s*!", icon = "$", lang = "bash" },
                    lua = { pattern = "^:%s*lua%s+", icon = "", lang = "lua" },
                    help = { pattern = "^:%s*he?l?p?%s+", icon = "󰋖" },
                },
            },
            views = {
                -- Main command palette popup shown when typing `:` or `/`.
                cmdline_popup = {
                    position = { row = "35%", col = "50%" },
                    size = { width = 70, height = "auto" },
                    border = { style = "rounded", padding = { 0, 1 } },
                    win_options = { winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder" },
                },
                -- Completion popup for command-line suggestions.
                popupmenu = {
                    relative = "editor",
                    position = { row = "43%", col = "50%" },
                    size = { width = 70, height = 10 },
                    border = { style = "rounded", padding = { 0, 1 } },
                },
            },
            presets = {
                bottom_search = false,
                command_palette = true,
                long_message_to_split = true,
                inc_rename = false,
                lsp_doc_border = true,
            },
            lsp = {
                -- Let noice render common LSP markdown documentation in a nicer
                -- popup while keeping the built-in LSP client underneath.
                override = {
                    ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
                    ["vim.lsp.util.stylize_markdown"] = true,
                },
            },
            routes = {
                -- Suppress noisy save messages because statusline/git signs
                -- already make successful writes obvious.
                { filter = { event = "msg_show", kind = "", find = "written" }, opts = { skip = true } },
            },
        },
    },
}
