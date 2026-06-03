-- Treesitter parser management and syntax features.
--
-- Current nvim-treesitter on Neovim v0.12 uses the newer
-- `require('nvim-treesitter')` API rather than the old
-- `nvim-treesitter.configs` module. This file follows that API, installs a
-- curated parser set, and enables highlighting/folds/indentation on supported
-- filetypes.

return {
    {
        "nvim-treesitter/nvim-treesitter",
        -- nvim-treesitter should not be lazy-loaded because parser/query paths
        -- and FileType hooks need to be ready as soon as buffers open.
        lazy = false,
        build = ":TSUpdate",
        config = function()
            local ok, treesitter = pcall(require, "nvim-treesitter")
            if not ok then
                vim.notify(
                    "nvim-treesitter was not loaded correctly. Run :Lazy sync, then restart Neovim.",
                    vim.log.levels.ERROR
                )
                return
            end

            -- Default setup is enough for the current API. Feature enabling is
            -- handled by the FileType autocmd below.
            treesitter.setup()

            -- Parsers installed automatically when the tree-sitter CLI is new
            -- enough. This covers shell, config, Markdown, Lua, and common web
            -- development languages without installing every parser available.
            local parsers = {
                "bash",
                "css",
                "html",
                "javascript",
                "json",
                "lua",
                "luadoc",
                "markdown",
                "markdown_inline",
                "python",
                "query",
                "regex",
                "toml",
                "tsx",
                "typescript",
                "vim",
                "vimdoc",
                "yaml",
            }

            -- Guard against old distro tree-sitter binaries. Current
            -- nvim-treesitter calls `tree-sitter build`, which was introduced
            -- after the older 0.20.x packages shipped by some distros.
            local function tree_sitter_cli_is_new_enough()
                if vim.fn.executable("tree-sitter") ~= 1 then
                    return false, "tree-sitter CLI was not found"
                end

                local output = vim.fn.system({ "tree-sitter", "--version" })
                local major, minor, patch = output:match("(%d+)%.(%d+)%.(%d+)")
                major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
                if not major or not minor or not patch then
                    return false, "could not parse tree-sitter CLI version: " .. vim.trim(output)
                end

                local ok_version = major > 0 or minor > 26 or (minor == 26 and patch >= 1)
                if not ok_version then
                    return false, "tree-sitter CLI " .. major .. "." .. minor .. "." .. patch .. " is older than 0.26.1"
                end

                return true, nil
            end

            -- Install missing parsers asynchronously when possible. If the CLI
            -- is too old, show a warning instead of breaking first startup.
            local cli_ok, cli_reason = tree_sitter_cli_is_new_enough()
            if cli_ok then
                treesitter.install(parsers)
            else
                vim.schedule(function()
                    vim.notify(
                        cli_reason
                        .. "; skipping automatic Treesitter parser installation. "
                        .. "Run bash setup.sh to install the managed tree-sitter CLI, then run :TSInstall bash lua markdown vimdoc yaml",
                        vim.log.levels.WARN
                    )
                end)
            end

            -- Filetypes where this config enables Treesitter features. The
            -- parser names above and filetype names here are intentionally not
            -- identical; for example `.env` files are treated as `sh`.
            local filetypes = {
                "bash",
                "css",
                "html",
                "javascript",
                "json",
                "jsonc",
                "lua",
                "markdown",
                "python",
                "sh",
                "toml",
                "tsx",
                "typescript",
                "vim",
                "vimdoc",
                "yaml",
            }

            vim.api.nvim_create_autocmd("FileType", {
                group = vim.api.nvim_create_augroup("user-treesitter", { clear = true }),
                pattern = filetypes,
                callback = function()
                    -- Highlighting and folds are built into Neovim; indentation
                    -- still comes from nvim-treesitter.
                    pcall(vim.treesitter.start)
                    vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
                    vim.wo.foldmethod = "expr"
                    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
                end,
            })
        end,
    },
}
