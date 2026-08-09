local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local plenary_path = os.getenv("PLENARY_PATH") or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")

vim.opt.rtp:prepend(plugin_root)
vim.opt.rtp:prepend(plenary_path)

-- tests/ isn't under lua/, so it needs an explicit package.path entry for
-- require("tests.helpers") to resolve.
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/logsvim.lua")

-- Every config.setup() call re-derives M.options from M.defaults, so
-- overriding the default here once keeps every test's index.refresh()
-- writes (async, via index.lua's write_cache) inside a throwaway tempdir
-- instead of the user's real cache_dir -- no spec file needs to remember to
-- pass cache_dir itself. Individual tests that care about cache_dir's
-- content (graph_spec.lua, index_spec.lua) still set their own on top.
require("logsvim.config").defaults.cache_dir = vim.fn.tempname()
