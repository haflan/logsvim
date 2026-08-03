if vim.g.loaded_logsvim then
  return
end
vim.g.loaded_logsvim = true

local pages = require("logsvim.pages")
local journal = require("logsvim.journal")
local buffer = require("logsvim.buffer")
local index = require("logsvim.index")
local graph = require("logsvim.graph")

journal.setup_autocmds()
buffer.setup_autocmds()
pages.setup_autocmds()

vim.api.nvim_create_user_command("LogsvimPage", function(opts)
  pages.open(opts.args)
end, { nargs = 1, desc = "Show a page's contents and its journal backlinks" })

vim.api.nvim_create_user_command("LogsvimJournal", function()
  journal.open()
end, { desc = "Open the scrollable, editable journal buffer" })

vim.api.nvim_create_user_command("LogsvimReindex", function()
  graph.resolve_root(function(root)
    if not root then
      return
    end
    index.refresh(root, function(names)
      vim.notify(("logsvim: indexed %d page(s)"):format(#names), vim.log.levels.INFO)
    end)
  end)
end, { desc = "Rebuild the logsvim [[Page]] link index" })
