-- Editor workflow plugins.
--
-- This module collects tools that improve day-to-day editing but are not part
-- of the core LSP/syntax/UI foundation: fuzzy finding, file explorer, Git signs,
-- automatic pairs, and formatting. Most plugins are lazy-loaded on commands,
-- keys, or buffer events to keep startup fast.

return {
    {
        -- Telescope is the primary picker for files, buffers, grep, help, and
        -- recent files. It is exposed through leader mappings and only loads
        -- when one of those mappings or `:Telescope` is used.
        "nvim-telescope/telescope.nvim",
        cmd = "Telescope",
        dependencies = {
            "nvim-lua/plenary.nvim",
            {
                -- Native sorter for much faster Telescope fuzzy matching. It
                -- requires `make`, so the spec is skipped if build tools are
                -- unavailable.
                "nvim-telescope/telescope-fzf-native.nvim",
                build = "make",
                cond = function()
                    return vim.fn.executable("make") == 1
                end,
            },
        },
        keys = {
            { "<leader>ff", "<cmd>Telescope find_files<CR>", desc = "Find files" },
            { "<leader>fg", "<cmd>Telescope live_grep<CR>",  desc = "Live grep" },
            { "<leader>fb", "<cmd>Telescope buffers<CR>",    desc = "Find buffers" },
            { "<leader>fh", "<cmd>Telescope help_tags<CR>",  desc = "Help tags" },
            { "<leader>fr", "<cmd>Telescope oldfiles<CR>",   desc = "Recent files" },
        },
        opts = {
            defaults = {
                prompt_prefix = "   ",
                selection_caret = " ",
                path_display = { "smart" },
                mappings = {
                    i = { ["<C-j>"] = "move_selection_next", ["<C-k>"] = "move_selection_previous" },
                },
            },
        },
        config = function(_, opts)
            local telescope = require("telescope")
            telescope.setup(opts)
            -- Loading the extension is optional because it depends on a local
            -- native build; `pcall` keeps Telescope usable if the build failed.
            pcall(telescope.load_extension, "fzf")
        end,
    },

    {
        -- Neo-tree is the file explorer. It is configured to reveal the current
        -- file, show dotfiles, and avoid staying open as the final window.
        "nvim-neo-tree/neo-tree.nvim",
        branch = "v3.x",
        dependencies = {
            "nvim-lua/plenary.nvim",
            "nvim-tree/nvim-web-devicons",
            "MunifTanjim/nui.nvim",
        },
        keys = {
            { "<leader>e", "<cmd>Neotree toggle reveal<CR>", desc = "Explorer" },
        },
        opts = {
            close_if_last_window = true,
            popup_border_style = "rounded",
            filesystem = {
                follow_current_file = { enabled = true },
                filtered_items = { visible = true, hide_dotfiles = false, hide_gitignored = true },
            },
            window = { width = 32 },
        },
    },

    {
        -- Git signs show changed/added/deleted lines in the sign column without
        -- needing a full Git UI plugin.
        "lewis6991/gitsigns.nvim",
        event = { "BufReadPost", "BufNewFile" },
        opts = {
            signs = {
                add = { text = "▎" },
                change = { text = "▎" },
                delete = { text = "" },
                topdelete = { text = "" },
                changedelete = { text = "▎" },
            },
        },
    },

    {
        -- Automatically inserts matching brackets, quotes, and similar pairs in
        -- insert mode.
        "windwp/nvim-autopairs",
        event = "InsertEnter",
        opts = {},
    },

    {
        -- conform.nvim provides a single formatting interface. It prefers
        -- external formatters when configured and falls back to LSP formatting.
        "stevearc/conform.nvim",
        event = { "BufWritePre" },
        cmd = { "ConformInfo" },
        keys = {
            {
                "<leader>f",
                function()
                    require("conform").format({ async = true, lsp_format = "fallback" })
                end,
                mode = { "n", "v" },
                desc = "Format buffer",
            },
        },
        opts = {
            notify_on_error = false,
            format_on_save = function(bufnr)
                -- Avoid surprise formatting for C/C++ because style preferences
                -- are often project-specific and clang-format may be absent.
                local disabled = { c = true, cpp = true }
                if disabled[vim.bo[bufnr].filetype] then
                    return nil
                end
                return { timeout_ms = 500, lsp_format = "fallback" }
            end,
            formatters_by_ft = {
                lua = { "stylua" },
                sh = { "shfmt" },
                bash = { "shfmt" },
                javascript = { "prettierd", "prettier", stop_after_first = true },
                typescript = { "prettierd", "prettier", stop_after_first = true },
                json = { "prettierd", "prettier", stop_after_first = true },
                yaml = { "prettierd", "prettier", stop_after_first = true },
                markdown = { "prettierd", "prettier", stop_after_first = true },
            },
        },
    },
}
