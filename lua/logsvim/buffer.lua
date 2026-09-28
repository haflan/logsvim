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
function M.attach(bufnr, root)
  if vim.b[bufnr].logsvim_attached then
    return
  end
  vim.b[bufnr].logsvim_attached = true

  edit.attach(bufnr)
  attach_cmp(bufnr)
  if vim.bo[bufnr].buftype == "" then
    -- A real file: let Neovim reload it when it changes on disk and the
    -- buffer has no unsaved edits (it warns instead when it has). The
    -- autocmds below make sure it actually checks.
    vim.bo[bufnr].autoread = true
  end
  index.ensure_loaded(root or graph.root())
end

-- Run `fn` with the view (cursor, scroll) of every window showing `bufnr`
-- restored afterwards, so replacing regions above the cursor doesn't make
-- the text jump around under the user.
function M.keep_views(bufnr, fn)
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  fn()
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

-- Whether `path` (a real file, not the logsvim-journal:// virtual buffer)
-- lives inside `root`'s journal_dir or pages_dir.
function M.is_graph_path(path, root)
  local full = vim.fn.fnamemodify(path, ":p")
  local jd = vim.fn.fnamemodify(graph.journal_dir(root), ":p")
  local pd = vim.fn.fnamemodify(graph.pages_dir(root), ":p")
  return vim.startswith(full, jd) or vim.startswith(full, pd)
end

-- Check a real graph file for changes made elsewhere (see 'autoread' in
-- M.attach). Virtual logsvim buffers do their own reloading.
local function checktime(bufnr)
  if vim.bo[bufnr].buftype == "" then
    vim.cmd("checktime " .. bufnr)
  end
end

-- Auto-attach to real journal/page files (e.g. opened via :LogsvimPage's
-- quickfix list, or `gd`) that aren't routed through the journal.lua virtual
-- buffer and so wouldn't otherwise pick up bullet-editing/completion. Goes
-- through graph.resolve_root() rather than the raw (possibly still
-- unresolved) graph.root(), so this also works the first time a graph file
-- is opened directly, before any :Logsvim* command has run. Resolves
-- silently since this fires on every *.md buffer, including ones outside
-- any graph -- an explicit :Logsvim* command is still the one that notifies
-- or prompts on failure.
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("logsvim_buffer", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = "*.md",
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path == "" then
        return
      end
      graph.resolve_root(function(root)
        if root and vim.api.nvim_buf_is_valid(args.buf) and M.is_graph_path(path, root) then
          M.attach(args.buf, root)
          checktime(args.buf)
        end
      end, { silent = true })
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].logsvim_attached then
          checktime(bufnr)
        end
      end
    end,
  })
end

return M
