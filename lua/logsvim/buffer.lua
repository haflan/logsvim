local graph = require("logsvim.graph")
local edit = require("logsvim.edit")
local index = require("logsvim.index")

local M = {}

local cmp_source_registered = false

local function attach_cmp(bufnr)
  local ok, cmp = pcall(require, "cmp")
  if not ok then
    return
  end

  if not cmp_source_registered then
    cmp.register_source("logsvim_pages", require("logsvim.cmp_source").new())
    cmp_source_registered = true
  end

  cmp.setup.buffer({
    sources = cmp.config.sources({ { name = "logsvim_pages" } }, cmp.get_config().sources or {}),
  })
end

-- Wire up bullet-continuation editing and [[ ]] completion for `bufnr`.
-- Safe to call more than once per buffer.
function M.attach(bufnr)
  if vim.b[bufnr].logsvim_attached then
    return
  end
  vim.b[bufnr].logsvim_attached = true

  edit.attach(bufnr)
  attach_cmp(bufnr)
  index.ensure_loaded(graph.root())
end

-- Whether `path` (a real file, not the logsvim-journal:// virtual buffer)
-- lives inside the graph's journal_dir or pages_dir.
function M.is_graph_path(path, root)
  root = root or graph.root()
  local full = vim.fn.fnamemodify(path, ":p")
  local jd = vim.fn.fnamemodify(graph.journal_dir(root), ":p")
  local pd = vim.fn.fnamemodify(graph.pages_dir(root), ":p")
  return vim.startswith(full, jd) or vim.startswith(full, pd)
end

-- Auto-attach to real journal/page files (e.g. opened via :LogsvimPage's
-- quickfix list, or `gd`) that aren't routed through the journal.lua virtual
-- buffer and so wouldn't otherwise pick up bullet-editing/completion.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("logsvim_buffer", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.md",
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path ~= "" and M.is_graph_path(path) then
        M.attach(args.buf)
      end
    end,
  })
end

return M
