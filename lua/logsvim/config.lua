local M = {}

M.defaults = {
  -- Graph root containing journals/, pages/, assets/.
  root = vim.fn.getcwd(),
  -- One of "tab" (default), "two-spaces", "four-spaces", "eight-spaces" —
  -- matches Logseq's :export/bullet-indentation config.edn values exactly.
  indentation = "tab",
  -- Task workflow for keymaps.cycle_task: "now" (LATER -> NOW -> DONE) or
  -- "todo" (TODO -> DOING -> DONE). Matches Logseq's :preferred-workflow,
  -- whose default is :now.
  workflow = "now",
  journal_dir = "journals",
  pages_dir = "pages",
  assets_dir = "assets",
  -- Go's "2006_01_02" in Lua's os.date format.
  date_format = "%Y_%m_%d",
  -- Number of journal files loaded per batch in :LogsvimJournal.
  journal_batch_size = 14,
  -- Where the [[Page]] link index (used for completion) is cached on disk.
  cache_dir = "~/.cache/logsvim",
  -- Normal-mode keymaps set in journal/page buffers. Each value is a key or
  -- list of keys, or false to leave that action unbound.
  keymaps = {
    goto_reference = { "gd", "<CR>" },
    rename = "<leader>rn",
    -- Normal and insert mode.
    cycle_task = "<C-CR>",
  },
}

M.options = vim.deepcopy(M.defaults)

-- Whether `root` was explicitly passed to the most recent setup() call, as
-- opposed to falling back to defaults.root's cwd snapshot. graph.resolve_root()
-- trusts an explicit root outright, skipping cwd/parent/cache discovery.
M.explicit_root = false

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Recompute `keymaps` as a shallow, per-action merge rather than trusting
  -- the deep_extend above: since goto_reference's default is itself a list,
  -- deep-merging it against a user-supplied shorter list would merge by
  -- index and leave a stray default entry behind instead of replacing it.
  if opts.keymaps then
    M.options.keymaps = vim.tbl_extend("force", vim.deepcopy(M.defaults.keymaps), opts.keymaps)
  end
  M.explicit_root = opts.root ~= nil
end

-- Bind `rhs` to every key configured for keymaps.<name> (e.g.
-- "goto_reference") in buffer `bufnr`, in `modes` (default normal mode).
-- No-op if that action is unset/false.
function M.set_keymap(bufnr, name, rhs, desc, modes)
  local lhs = M.options.keymaps and M.options.keymaps[name]
  if not lhs then
    return
  end
  if type(lhs) == "string" then
    lhs = { lhs }
  end
  for _, key in ipairs(lhs) do
    vim.keymap.set(modes or "n", key, rhs, { buffer = bufnr, desc = desc })
  end
end

return M
