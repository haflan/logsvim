local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local plenary_path = os.getenv("PLENARY_PATH") or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")

vim.opt.rtp:prepend(plugin_root)
vim.opt.rtp:prepend(plenary_path)

-- tests/ isn't under lua/, so it needs an explicit package.path entry for
-- require("tests.helpers") to resolve.
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/logsvim.lua")
