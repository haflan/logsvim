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
end, {
  nargs = 1,
  desc = "Show a page's contents and its journal backlinks",
  -- Match against the whole remaining command line rather than the
  -- ArgLead Vim would pass in (which splits on spaces), so completion
  -- still works for page names containing spaces (e.g. "Plugin Ideas").
  complete = function(_, cmd_line)
    local arg_lead = cmd_line:match("^LogsvimPage!?%s*(.*)$") or ""
    local matches = {}
    for _, name in ipairs(pages.completion_names(graph.root())) do
      if name:sub(1, #arg_lead) == arg_lead then
        table.insert(matches, name)
      end
    end
    return matches
  end,
})

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

vim.api.nvim_create_user_command("LogsvimReload", function(opts)
  local opts_reload = { discard = opts.bang }
  local function reload(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("^logsvim%-journal://") then
      journal.reload(bufnr, opts_reload)
      return true
    elseif name:match("^logsvim%-page://") then
      pages.reload(bufnr, opts_reload)
      return true
    end
    return false
  end

  -- The current buffer if it's a logsvim one, otherwise every loaded one.
  if not reload(vim.api.nvim_get_current_buf()) then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        reload(bufnr)
      end
    end
  end
end, {
  bang = true,
  desc = "Pick up changes made on disk; with !, discard unsaved edits",
})
